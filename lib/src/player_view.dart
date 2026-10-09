import 'dart:async';

import 'package:flutter/material.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'controller.dart';
import 'controls_configuration.dart';
import 'models.dart';
import 'statistics_view.dart';

export 'controls_configuration.dart';

typedef LumioPlaceholderBuilder =
    Widget Function(BuildContext context, LumioPlayerState state);
typedef LumioErrorBuilder =
    Widget Function(BuildContext context, LumioPlayerError error);

Future<void> _run(
  BuildContext? context,
  LumioPlayerController controller,
  Future<void> Function() command,
) async {
  final messenger = context == null || !context.mounted
      ? null
      : ScaffoldMessenger.maybeOf(context);
  try {
    await command();
  } catch (_) {
    // Never include exception text: platform errors can contain credentials.
    final entry = LumioLogEntry(
      LumioLogLevel.warning,
      'controls_command_failed',
      'Player command failed. Retry or inspect player diagnostics.',
    );
    try {
      controller.logger?.call(entry);
    } catch (_) {
      // A consumer logger must not turn a handled command into an async error.
    }
    if (context != null && context.mounted) {
      messenger?.showSnackBar(SnackBar(content: Text(entry.message)));
    }
  }
}

bool _ready(LumioPlayerState state) =>
    state.initialized && !state.transitioning && state.error == null;
bool _live(LumioPlayerController controller) =>
    controller.value.live ||
    controller.configuration.mode == LumioPlaybackMode.live;
bool _seekable(LumioPlayerController controller) =>
    _ready(controller.value) &&
    !_live(controller) &&
    controller.value.duration > Duration.zero;

Future<void> _skip(
  BuildContext context,
  LumioPlayerController controller,
  Duration delta,
) => _run(context, controller, () {
  if (!_seekable(controller)) return Future.value();
  final state = controller.value;
  return controller.seekTo(
    Duration(
      milliseconds: (state.position + delta).inMilliseconds.clamp(
        0,
        state.duration.inMilliseconds,
      ),
    ),
  );
});

String _time(Duration duration) {
  final seconds = duration.inSeconds.clamp(0, 1 << 53);
  final minutes = (seconds ~/ 60) % 60;
  final remainder = (seconds % 60).toString().padLeft(2, '0');
  return seconds >= 3600
      ? '${seconds ~/ 3600}:${minutes.toString().padLeft(2, '0')}:$remainder'
      : '${seconds ~/ 60}:$remainder';
}

/// Aspect-ratio surface, or expansion into the finite area supplied by the host.
enum LumioVideoLayout { aspectRatio, expand }

/// Mount before opening media, including audio. The caller owns the controller.
/// Move this view for fullscreen; do not mount two views for one WebView.
///
/// [controls] is the backwards-compatible master switch for chrome AND gestures.
/// Loading remains controlled independently by [controlsConfiguration.showLoader].
class LumioPlayerView extends StatefulWidget {
  const LumioPlayerView({
    super.key,
    required this.controller,
    this.controls = true,
    this.controlsConfiguration = const LumioControlsConfiguration(),
    this.title,
    this.fit,
    this.layout = LumioVideoLayout.aspectRatio,
    this.aspectRatio,
    this.placeholder,
    this.errorBuilder,
  }) : assert(
         aspectRatio == null ||
             (aspectRatio > 0 && aspectRatio < double.infinity),
       );

  final LumioPlayerController controller;
  final bool controls;
  final LumioControlsConfiguration controlsConfiguration;

  /// Overrides the controller's current item/single-source title.
  final String? title;

  /// Null follows controller.videoFit, whose default is BoxFit.contain.
  final BoxFit? fit;
  final LumioVideoLayout layout;
  final double? aspectRatio;
  final LumioPlaceholderBuilder? placeholder;
  final LumioErrorBuilder? errorBuilder;

  @override
  State<LumioPlayerView> createState() => _LumioPlayerViewState();
}

/// A temporary rate belongs to the controller, not to a playlist item. Native
/// auto-advance and engine reopening inherit its persistent playback rate.
class _HoldSpeedSession {
  _HoldSpeedSession(this.controller, this.speed)
    : originalSpeed = controller.value.speed;

  final LumioPlayerController controller;
  final double originalSpeed, speed;
  late final Future<void> _boost;
  bool applied = false;
  bool _superseded = false;
  late final int _revision;

  void _observe() {
    final current = controller.value.speed;
    if (current == speed) {
      applied = true;
    } else if (applied || current != originalSpeed) {
      _superseded = true;
    }
  }

  void start(BuildContext context) {
    controller.addListener(_observe);
    _boost = _run(context, controller, () => controller.setSpeed(speed));
    _revision = controller.speedRevision;
  }

  Future<void> release() async {
    try {
      // Release can precede the platform's boost acknowledgement. Check ownership
      // only afterwards, and restore on the captured controller even across items.
      await _boost;
      if (!_superseded && controller.value.speed == speed) {
        await _run(
          null,
          controller,
          () => controller.restoreSpeedIfUnchanged(
            revision: _revision,
            temporarySpeed: speed,
            originalSpeed: originalSpeed,
          ),
        );
      }
    } finally {
      controller.removeListener(_observe);
    }
  }
}

class _LumioPlayerViewState extends State<LumioPlayerView> {
  Timer? _compactTimer;
  bool _hidden = false, _interacting = false, _holding = false;
  final Set<int> _pointers = {};
  _HoldSpeedSession? _holdSession;
  LumioSource? _source;
  int? _index;
  LumioPlaybackEngine? _engine;
  double _zoom = 1, _startZoom = 1;
  Offset _pan = Offset.zero, _anchor = Offset.zero;
  Size _viewport = Size.zero;

  LumioControlsConfiguration get _config => widget.controlsConfiguration;
  LumioPlayerController get _controller => widget.controller;
  bool get _enabled => widget.controls && _config.enabled;

  @override
  void initState() {
    super.initState();
    _config.validate();
    if (widget.fit != null) {
      unawaited(
        _run(null, _controller, () => _controller.setVideoFit(widget.fit!)),
      );
    }
    _source = _controller.source;
    _index = _controller.playlistIndex;
    _engine = _controller.value.engine;
    _controller.addListener(_changed);
    _schedule();
  }

  @override
  void didUpdateWidget(LumioPlayerView oldWidget) {
    super.didUpdateWidget(oldWidget);
    _config.validate();
    if (widget.fit != null &&
        (oldWidget.fit != widget.fit || oldWidget.controller != _controller)) {
      unawaited(
        _run(null, _controller, () => _controller.setVideoFit(widget.fit!)),
      );
    }
    if (oldWidget.controller != _controller) {
      _endHold();
      oldWidget.controller.removeListener(_changed);
      _controller.addListener(_changed);
      _source = _controller.source;
      _index = _controller.playlistIndex;
      _engine = _controller.value.engine;
      _resetZoom();
    }
    if (!_enabled || !_config.holdToSpeed) _endHold();
    if (!_enabled || !_config.enableZoom) _resetZoom();
    _hidden = false;
    _schedule();
  }

  void _resetZoom() {
    _zoom = _startZoom = 1;
    _pan = _anchor = Offset.zero;
  }

  void _changed() {
    final state = _controller.value;
    final sourceChanged =
        !identical(_source, _controller.source) ||
        _index != _controller.playlistIndex;
    if (sourceChanged ||
        _engine != state.engine ||
        !_ready(state) ||
        _live(_controller) ||
        (_holdSession?.applied == true && state.speed != _holdSession?.speed)) {
      _endHold();
    }
    if (sourceChanged) _resetZoom();
    _source = _controller.source;
    _index = _controller.playlistIndex;
    _engine = state.engine;
    if (!state.playing || !_ready(state) || state.buffering) _hidden = false;
    // Position notifications must not keep pushing the inactivity deadline back.
    if (!_canHide) {
      _compactTimer?.cancel();
      _compactTimer = null;
    } else if (!_hidden && _compactTimer == null) {
      _schedule();
    }
    setState(() {});
  }

  bool get _canHide =>
      _enabled &&
      _config.compact &&
      _controller.value.playing &&
      _ready(_controller.value) &&
      !_controller.value.buffering &&
      !_interacting &&
      !_holding;

  void _schedule() {
    _compactTimer?.cancel();
    _compactTimer = null;
    if (!_canHide) return;
    _compactTimer = Timer(_config.compactDelay, () {
      _compactTimer = null;
      if (mounted && _canHide) setState(() => _hidden = true);
    });
  }

  void _reveal() {
    if (!mounted) return;
    setState(() => _hidden = false);
    _schedule();
  }

  void _interaction(bool active) {
    _interacting = active;
    _reveal();
  }

  void _beginHold() {
    if (!_enabled ||
        !_config.holdToSpeed ||
        _pointers.length > 1 ||
        !_ready(_controller.value) ||
        _live(_controller) ||
        _holdSession != null) {
      return;
    }
    _holding = true;
    final session = _HoldSpeedSession(_controller, _config.holdSpeed);
    _holdSession = session;
    _reveal();
    session.start(context);
  }

  void _endHold() {
    if (!_holding) return;
    final session = _holdSession!;
    _holding = false;
    unawaited(
      session.release().whenComplete(() {
        if (identical(_holdSession, session)) _holdSession = null;
      }),
    );
    _schedule();
  }

  Offset _clampPan(Offset pan) {
    final x = _viewport.width * (_zoom - 1) / 2;
    final y = _viewport.height * (_zoom - 1) / 2;
    return Offset(pan.dx.clamp(-x, x), pan.dy.clamp(-y, y));
  }

  @override
  void dispose() {
    _compactTimer?.cancel();
    _controller.removeListener(_changed);
    _endHold();
    // _endHold may schedule a new timer while the old state is still mounted.
    _compactTimer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final state = _controller.value;
    final web = _controller.webViewController;
    final texture = _controller.textureId;
    final audio = _controller.configuration.mode == LumioPlaybackMode.audio;
    final hasSurface = web != null || texture != null;
    final size = state.size.width > 0 && state.size.height > 0
        ? state.size
        : const Size(1600, 900);
    return LayoutBuilder(
      builder: (context, constraints) {
        if (widget.layout == LumioVideoLayout.expand &&
            !constraints.hasBoundedHeight) {
          throw FlutterError(
            'LumioVideoLayout.expand requires a finite height. Wrap LumioPlayerView with Expanded or SizedBox(height: ...), not an unbounded scroll view.',
          );
        }
        return Column(
          mainAxisSize: widget.layout == LumioVideoLayout.expand
              ? MainAxisSize.max
              : MainAxisSize.min,
          children: [
            _surfaceFrame(
              child: LayoutBuilder(
                builder: (context, constraints) {
                  _viewport = constraints.biggest;
                  return Listener(
                    onPointerDown: _enabled
                        ? (event) {
                            _pointers.add(event.pointer);
                            if (_pointers.length > 1) _endHold();
                            _interaction(true);
                          }
                        : null,
                    onPointerUp: _enabled
                        ? (event) {
                            _pointers.remove(event.pointer);
                            _endHold();
                            if (_pointers.isEmpty) _interaction(false);
                          }
                        : null,
                    onPointerCancel: _enabled
                        ? (event) {
                            _pointers.remove(event.pointer);
                            _endHold();
                            if (_pointers.isEmpty) _interaction(false);
                          }
                        : null,
                    child: GestureDetector(
                      key: const ValueKey('lumio-gesture-surface'),
                      behavior: HitTestBehavior.opaque,
                      onTap: _enabled ? _reveal : null,
                      onDoubleTapDown: _enabled && _config.doubleTapSeek
                          ? (details) {
                              _reveal();
                              unawaited(
                                _skip(
                                  context,
                                  _controller,
                                  details.localPosition.dx < _viewport.width / 2
                                      ? -_config.seekInterval
                                      : _config.seekInterval,
                                ),
                              );
                            }
                          : null,
                      onDoubleTap: _enabled && _config.doubleTapSeek
                          ? () {}
                          : null,
                      onLongPressStart: _enabled && _config.holdToSpeed
                          ? (_) => _beginHold()
                          : null,
                      onLongPressEnd: _enabled && _config.holdToSpeed
                          ? (_) {
                              _endHold();
                              _reveal();
                            }
                          : null,
                      onLongPressCancel: _enabled && _config.holdToSpeed
                          ? _endHold
                          : null,
                      onScaleStart: _enabled && _config.enableZoom
                          ? (details) {
                              _endHold();
                              _startZoom = _zoom;
                              _anchor = details.localFocalPoint;
                            }
                          : null,
                      onScaleUpdate: _enabled && _config.enableZoom
                          ? (details) {
                              if (!_ready(state) || audio) return;
                              // One finger may pan an already zoomed surface, but cannot
                              // start a speed hold after a second pointer joins the gesture.
                              setState(() {
                                _zoom = (_startZoom * details.scale).clamp(
                                  1,
                                  _config.maxZoom,
                                );
                                _pan = _clampPan(
                                  _pan + details.localFocalPoint - _anchor,
                                );
                                _anchor = details.localFocalPoint;
                              });
                            }
                          : null,
                      child: ClipRect(
                        child: Stack(
                          fit: StackFit.expand,
                          children: [
                            const ColoredBox(color: Colors.black),
                            // Keep this transform/surface branch stable as chrome hides.
                            Transform(
                              key: const ValueKey('lumio-surface-transform'),
                              alignment: Alignment.center,
                              transform: Matrix4.identity()
                                ..translateByDouble(_pan.dx, _pan.dy, 0, 1)
                                ..scaleByDouble(_zoom, _zoom, 1, 1),
                              child: AbsorbPointer(
                                absorbing: _enabled,
                                child: web != null
                                    ? WebViewWidget(
                                        key: ObjectKey(web),
                                        controller: web,
                                      )
                                    : texture != null
                                    ? FittedBox(
                                        fit: widget.fit ?? _controller.videoFit,
                                        child: SizedBox(
                                          width: size.width,
                                          height: size.height,
                                          child: Texture(textureId: texture),
                                        ),
                                      )
                                    : const SizedBox.expand(),
                              ),
                            ),
                            if (audio || !hasSurface || !state.initialized)
                              IgnorePointer(
                                child: ColoredBox(
                                  color: audio || !hasSurface
                                      ? Colors.black
                                      : Colors.black54,
                                  child:
                                      widget.placeholder?.call(
                                        context,
                                        state,
                                      ) ??
                                      Center(
                                        child: Icon(
                                          audio
                                              ? Icons.audiotrack
                                              : Icons.play_circle_outline,
                                          size: 48,
                                          color: Colors.white70,
                                          semanticLabel: audio
                                              ? 'Audio player'
                                              : 'Video player',
                                        ),
                                      ),
                                ),
                              ),
                            if (_config.showLoader &&
                                (state.buffering || state.transitioning))
                              const IgnorePointer(
                                child: Center(
                                  child: CircularProgressIndicator(
                                    semanticsLabel: 'Loading media',
                                  ),
                                ),
                              ),
                            if (state.error case final error?)
                              ColoredBox(
                                color: Colors.black87,
                                child:
                                    widget.errorBuilder?.call(context, error) ??
                                    Center(
                                      child: Padding(
                                        padding: const EdgeInsets.all(12),
                                        child: Text(
                                          'Playback failed (${error.code}).',
                                          textAlign: TextAlign.center,
                                          style: const TextStyle(
                                            color: Colors.white,
                                          ),
                                        ),
                                      ),
                                    ),
                              ),
                            if (_holding)
                              IgnorePointer(
                                child: Align(
                                  alignment: Alignment.topCenter,
                                  child: Padding(
                                    padding: const EdgeInsets.all(12),
                                    child: Text(
                                      '${_config.holdSpeed}x',
                                      style: const TextStyle(
                                        color: Colors.white,
                                        backgroundColor: Colors.black87,
                                      ),
                                    ),
                                  ),
                                ),
                              ),
                          ],
                        ),
                      ),
                    ),
                  );
                },
              ),
            ),
            if (_enabled)
              LumioPlayerControls(
                controller: _controller,
                configuration: _config,
                title: widget.title,
                compacted: _hidden,
                onInteraction: _interaction,
                beforeCommand: _endHold,
              ),
          ],
        );
      },
    );
  }

  Widget _surfaceFrame({required Widget child}) =>
      widget.layout == LumioVideoLayout.expand
      ? Expanded(child: child)
      : AspectRatio(
          aspectRatio: widget.aspectRatio ?? _controller.value.aspectRatio,
          child: child,
        );
}

/// Can be mounted independently of the view, with its own configuration.
/// Scrubbing is local until release; controller position events cannot move the
/// thumb during a drag. All asynchronous command failures are safely handled.
class LumioPlayerControls extends StatefulWidget {
  const LumioPlayerControls({
    super.key,
    required this.controller,
    this.configuration = const LumioControlsConfiguration(),
    this.title,
    this.compacted = false,
    this.onInteraction,
    this.beforeCommand,
  });

  final LumioPlayerController controller;
  final LumioControlsConfiguration configuration;
  final String? title;
  final bool compacted;
  final ValueChanged<bool>? onInteraction;
  final VoidCallback? beforeCommand;
  static const playbackSpeeds = <double>[1, 1.5, 2, 3, 4];

  @override
  State<LumioPlayerControls> createState() => _LumioPlayerControlsState();
}

class _LumioPlayerControlsState extends State<LumioPlayerControls> {
  double? _drag;
  LumioSource? _dragSource;
  int? _dragIndex;
  double _lastVolume = 1;

  LumioPlayerController get _controller => widget.controller;
  LumioControlsConfiguration get _config => widget.configuration;

  Future<void> _command(Future<void> Function() command) async {
    widget.beforeCommand?.call();
    widget.onInteraction?.call(true);
    try {
      await _run(context, _controller, command);
    } finally {
      if (mounted) widget.onInteraction?.call(false);
    }
  }

  void _menuOpened() => widget.onInteraction?.call(true);
  void _menuClosed() => widget.onInteraction?.call(false);

  @override
  void didUpdateWidget(LumioPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _controller) _drag = null;
  }

  @override
  Widget build(BuildContext context) {
    _config.validate();
    if (!_config.enabled) return const SizedBox.shrink();
    return ValueListenableBuilder<LumioPlayerState>(
      valueListenable: _controller,
      builder: (context, state, _) {
        final enabled = _ready(state);
        final live = _live(_controller);
        final seekable = _seekable(_controller);
        final duration = state.duration.inMilliseconds.toDouble();
        if (_drag != null &&
            (!seekable ||
                !identical(_dragSource, _controller.source) ||
                _dragIndex != _controller.playlistIndex)) {
          _drag = null;
          _dragSource = null;
          _dragIndex = null;
        }
        final progress = duration > 0
            ? (_drag ?? state.position.inMilliseconds.toDouble())
                  .clamp(0, duration)
                  .toDouble()
            : 0.0;
        final accent =
            _config.progressColor ?? Theme.of(context).colorScheme.primary;
        final title =
            widget.title ?? _controller.title ?? _controller.currentItem?.title;
        Widget button(String tooltip, IconData icon, VoidCallback? action) =>
            IconButton(tooltip: tooltip, icon: Icon(icon), onPressed: action);
        if (widget.compacted) {
          return Material(
            color: _config.backgroundColor,
            child: GestureDetector(
              key: const ValueKey('lumio-compact-controls'),
              behavior: HitTestBehavior.opaque,
              onTap: () {
                widget.onInteraction?.call(true);
                _menuClosed();
              },
              child: SizedBox(
                height: 6,
                child: Align(
                  alignment: Alignment.topCenter,
                  child: _config.showProgress && !live
                      ? LinearProgressIndicator(
                          key: const ValueKey('lumio-compact-progress'),
                          minHeight: 2,
                          color: accent,
                          backgroundColor: _config.foregroundColor.withValues(
                            alpha: .15,
                          ),
                          value: duration > 0 ? progress / duration : 0,
                        )
                      : const SizedBox.shrink(),
                ),
              ),
            ),
          );
        }
        return Material(
          color: _config.backgroundColor,
          child: IconTheme(
            data: IconThemeData(color: _config.foregroundColor, size: 22),
            child: DefaultTextStyle(
              style: TextStyle(color: _config.foregroundColor, fontSize: 12),
              child: Padding(
                padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: [
                    if (_config.showProgress && !live)
                      SliderTheme(
                        data: SliderTheme.of(context).copyWith(
                          activeTrackColor: accent,
                          thumbColor: accent,
                          inactiveTrackColor: _config.foregroundColor
                              .withValues(alpha: .2),
                          trackHeight: 3,
                        ),
                        child: Slider(
                          key: const ValueKey('lumio-progress'),
                          value: progress,
                          max: duration > 0 ? duration : 1,
                          label: _time(
                            Duration(milliseconds: progress.round()),
                          ),
                          semanticFormatterCallback: (value) =>
                              _time(Duration(milliseconds: value.round())),
                          onChangeStart: seekable
                              ? (value) {
                                  _dragSource = _controller.source;
                                  _dragIndex = _controller.playlistIndex;
                                  widget.onInteraction?.call(true);
                                }
                              : null,
                          onChanged: seekable
                              ? (value) {
                                  // Also support accessibility's discrete slider changes.
                                  _dragSource ??= _controller.source;
                                  _dragIndex ??= _controller.playlistIndex;
                                  setState(() => _drag = value);
                                }
                              : null,
                          onChangeEnd: seekable
                              ? (value) {
                                  final sameItem =
                                      identical(
                                        _dragSource,
                                        _controller.source,
                                      ) &&
                                      _dragIndex == _controller.playlistIndex;
                                  setState(() {
                                    _drag = null;
                                    _dragSource = null;
                                    _dragIndex = null;
                                  });
                                  if (sameItem && _seekable(_controller)) {
                                    unawaited(
                                      _command(
                                        () => _controller.seekTo(
                                          Duration(
                                            milliseconds: value.round().clamp(
                                              0,
                                              _controller
                                                  .value
                                                  .duration
                                                  .inMilliseconds,
                                            ),
                                          ),
                                        ),
                                      ),
                                    );
                                  } else {
                                    _menuClosed();
                                  }
                                }
                              : null,
                        ),
                      ),
                    if ((_config.showTitle &&
                            title != null &&
                            title.isNotEmpty) ||
                        _config.showTime)
                      Padding(
                        padding: const EdgeInsets.symmetric(
                          horizontal: 4,
                          vertical: 4,
                        ),
                        child: LayoutBuilder(
                          builder: (context, constraints) {
                            final hasTitle =
                                _config.showTitle &&
                                title != null &&
                                title.isNotEmpty;
                            final titleWidget = Row(
                              children: [
                                const Icon(Icons.sensors, size: 22),
                                const SizedBox(width: 8),
                                if (constraints.maxWidth >= 500)
                                  const Text('Em exibição · '),
                                Expanded(
                                  child: Text(
                                    title ?? '',
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style:
                                        _config.titleStyle ??
                                        const TextStyle(
                                          fontWeight: FontWeight.w600,
                                        ),
                                  ),
                                ),
                              ],
                            );
                            final timeWidget = Text(
                              live
                                  ? 'LIVE · ${_time(state.position)}'
                                  : '${_time(state.position)} / ${_time(state.duration)}',
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                            );
                            if (constraints.maxWidth >= 420) {
                              return Row(
                                children: [
                                  if (hasTitle)
                                    Expanded(child: titleWidget)
                                  else
                                    const Spacer(),
                                  if (_config.showTime) ...[
                                    const SizedBox(width: 12),
                                    timeWidget,
                                  ],
                                ],
                              );
                            }
                            return Column(
                              crossAxisAlignment: CrossAxisAlignment.stretch,
                              mainAxisSize: MainAxisSize.min,
                              children: [
                                if (hasTitle) titleWidget,
                                if (_config.showTime) timeWidget,
                              ],
                            );
                          },
                        ),
                      ),
                    Wrap(
                      spacing: 0,
                      runSpacing: 0,
                      crossAxisAlignment: WrapCrossAlignment.center,
                      children: [
                        if (_config.showPlayPause)
                          button(
                            state.playing ? 'Pause' : 'Play',
                            state.playing ? Icons.pause : Icons.play_arrow,
                            enabled
                                ? () => _command(
                                    state.playing
                                        ? _controller.pause
                                        : _controller.play,
                                  )
                                : null,
                          ),
                        if (_config.showPlaylistNavigation &&
                            _controller.playlist != null)
                          button(
                            'Previous item',
                            Icons.skip_previous,
                            !state.transitioning && _controller.hasPrevious
                                ? () => _command(_controller.previous)
                                : null,
                          ),
                        if (_config.showSkipButtons && !live) ...[
                          button(
                            'Seek backward',
                            Icons.replay_10,
                            seekable
                                ? () => _command(
                                    () => _skip(
                                      context,
                                      _controller,
                                      -_config.seekInterval,
                                    ),
                                  )
                                : null,
                          ),
                          button(
                            'Seek forward',
                            Icons.forward_10,
                            seekable
                                ? () => _command(
                                    () => _skip(
                                      context,
                                      _controller,
                                      _config.seekInterval,
                                    ),
                                  )
                                : null,
                          ),
                        ],
                        if (_config.showPlaylistNavigation &&
                            _controller.playlist != null)
                          button(
                            'Next item',
                            Icons.skip_next,
                            !state.transitioning && _controller.hasNext
                                ? () => _command(_controller.next)
                                : null,
                          ),
                        if (_config.showLiveButton && live)
                          button(
                            'Return to live',
                            Icons.live_tv,
                            enabled
                                ? () => _command(_controller.seekToLive)
                                : null,
                          ),
                        if (_config.showVolume) ...[
                          button(
                            state.volume == 0 ? 'Unmute' : 'Mute',
                            state.volume == 0
                                ? Icons.volume_off
                                : Icons.volume_up,
                            enabled
                                ? () {
                                    if (state.volume > 0) {
                                      _lastVolume = state.volume;
                                    }
                                    _command(
                                      () => _controller.setVolume(
                                        state.volume == 0
                                            ? (_controller
                                                      .capabilities
                                                      .volumeControl
                                                  ? _lastVolume
                                                  : 1)
                                            : 0,
                                      ),
                                    );
                                  }
                                : null,
                          ),
                          if (_controller.capabilities.volumeControl)
                            SizedBox(
                              width: 100,
                              child: Slider(
                                key: const ValueKey('lumio-volume'),
                                value: state.volume.clamp(0, 1),
                                semanticFormatterCallback: (value) =>
                                    'Volume ${(value * 100).round()}%',
                                onChangeStart: enabled
                                    ? (_) => _menuOpened()
                                    : null,
                                onChanged: enabled
                                    ? (value) {
                                        if (value > 0) _lastVolume = value;
                                        unawaited(
                                          _run(
                                            context,
                                            _controller,
                                            () => _controller.setVolume(value),
                                          ),
                                        );
                                      }
                                    : null,
                                onChangeEnd: enabled
                                    ? (_) => _menuClosed()
                                    : null,
                              ),
                            ),
                        ],
                        if (_config.showSpeed)
                          PopupMenuButton<double>(
                            tooltip: 'Playback speed',
                            enabled: enabled && !live,
                            initialValue: state.speed,
                            onOpened: _menuOpened,
                            onCanceled: _menuClosed,
                            onSelected: (speed) =>
                                _command(() => _controller.setSpeed(speed)),
                            itemBuilder: (_) => [
                              for (final speed in _config.playbackSpeeds)
                                PopupMenuItem(
                                  value: speed,
                                  child: Text('${speed}x'),
                                ),
                            ],
                            child: Padding(
                              padding: const EdgeInsets.all(12),
                              child: Text('${state.speed}x'),
                            ),
                          ),
                        if (_config.showSettings)
                          PopupMenuButton<LumioPlaybackEngine>(
                            tooltip: 'Playback engine',
                            enabled: !state.transitioning,
                            initialValue: _controller.requestedEngine,
                            onOpened: _menuOpened,
                            onCanceled: _menuClosed,
                            onSelected: (engine) =>
                                _command(() => _controller.setEngine(engine)),
                            itemBuilder: (_) => [
                              for (final engine in LumioPlaybackEngine.values)
                                PopupMenuItem(
                                  value: engine,
                                  child: Text(engine.name),
                                ),
                            ],
                            icon: const Icon(Icons.settings_input_component),
                          ),
                        if (_config.showStatistics)
                          button(
                            'Estatísticas para nerds',
                            Icons.analytics_outlined,
                            () async {
                              _menuOpened();
                              try {
                                await LumioStatisticsView.show(
                                  context,
                                  _controller,
                                );
                              } finally {
                                if (mounted) _menuClosed();
                              }
                            },
                          ),
                        if (_config.showRetry && state.error != null)
                          button(
                            'Retry',
                            Icons.refresh,
                            !state.transitioning
                                ? () => _command(_controller.retry)
                                : null,
                          ),
                      ],
                    ),
                  ],
                ),
              ),
            ),
          ),
        );
      },
    );
  }
}
