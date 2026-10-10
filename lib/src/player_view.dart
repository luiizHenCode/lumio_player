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

/// Wraps only the media branch, never the controls (e.g. host zoom/navigation).
typedef LumioMediaWrapper = Widget Function(BuildContext context, Widget media);

Future<void> _run(
  BuildContext? context,
  LumioPlayerController controller,
  Future<void> Function() command,
) async {
  await _runResult(context, controller, command);
}

Future<bool> _runResult(
  BuildContext? context,
  LumioPlayerController controller,
  Future<void> Function() command,
) async {
  final messenger = context == null || !context.mounted
      ? null
      : ScaffoldMessenger.maybeOf(context);
  try {
    await command();
    return true;
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
    return false;
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

String _speedLabel(double speed) =>
    '${speed == speed.roundToDouble() ? speed.toInt() : speed}x';

/// Aspect-ratio surface, or expansion into the finite area supplied by the host.
enum LumioVideoLayout { aspectRatio, expand }

/// Mount before opening media, including audio. The caller owns the controller.
/// Built-in fullscreen temporarily unmounts the inline surface before opening
/// its route, so a WebView is never attached to two views. The controller stays alive.
///
/// [controls] is the backwards-compatible master switch for chrome AND gestures.
/// Loading remains controlled independently by [controlsConfiguration.showLoader].
class LumioPlayerView extends StatefulWidget {
  const LumioPlayerView({
    super.key,
    required this.controller,
    this.controls = true,
    this.controlsConfiguration = const LumioControlsConfiguration(),
    this.compactedController,
    this.title,
    this.fit,
    this.layout = LumioVideoLayout.aspectRatio,
    this.aspectRatio,
    this.placeholder,
    this.errorBuilder,
    this.onToggleFullscreen,
    this.isFullscreen = false,
    this.surfaceCaptureKey,
    this.mediaWrapper,
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

  /// Optional presentation state shared across source/controller remounts.
  /// Owned and disposed by the host; true means compact controls.
  final ValueNotifier<bool>? compactedController;
  final LumioPlaceholderBuilder? placeholder;
  final LumioErrorBuilder? errorBuilder;

  /// Native frame capture boundary, excluding the controls. WebViews require
  /// platform/HTML capture rather than Flutter repaint-boundary screenshots.
  final GlobalKey? surfaceCaptureKey;

  /// Must preserve the finite constraints of the media area.
  final LumioMediaWrapper? mediaWrapper;

  /// Override fullscreen navigation when the host manages its own presentation.
  final VoidCallback? onToggleFullscreen;
  final bool isFullscreen;

  @override
  State<LumioPlayerView> createState() => _LumioPlayerViewState();
}

class _GestureFeedbackPill extends StatelessWidget {
  const _GestureFeedbackPill({
    super.key,
    required this.label,
    required this.icon,
    required this.semanticsLabel,
    this.labelKey,
    this.trailingIcon = false,
  });

  final String label, semanticsLabel;
  final IconData icon;
  final Key? labelKey;
  final bool trailingIcon;

  @override
  Widget build(BuildContext context) {
    final arrow = Icon(icon, size: 20, color: Colors.white);
    return Semantics(
      label: semanticsLabel,
      excludeSemantics: true,
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: Colors.black.withValues(alpha: 0.78),
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: Colors.white.withValues(alpha: 0.18)),
          boxShadow: [
            BoxShadow(
              color: Colors.black.withValues(alpha: 0.2),
              blurRadius: 12,
              offset: const Offset(0, 3),
            ),
          ],
        ),
        child: Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: [
              if (!trailingIcon) ...[arrow, const SizedBox(width: 8)],
              Text(
                label,
                key: labelKey,
                style: const TextStyle(
                  color: Colors.white,
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  letterSpacing: 0.3,
                ),
              ),
              if (trailingIcon) ...[const SizedBox(width: 8), arrow],
            ],
          ),
        ),
      ),
    );
  }
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
  Timer? _compactTimer, _seekFeedbackTimer;
  Duration _seekFeedback = Duration.zero;
  bool? _doubleTapForward;
  bool _compacted = false, _interacting = false, _holding = false;
  bool _disposing = false;
  bool get _hidden => _compacted;
  set _hidden(bool hidden) {
    _compacted = hidden;
    final presentation = widget.compactedController;
    if (!_disposing && presentation != null && presentation.value != hidden) {
      presentation.value = hidden;
    }
  }

  void _presentationChanged() {
    if (!mounted || _disposing) return;
    setState(() => _compacted = widget.compactedController!.value);
    if (_hidden) {
      _compactTimer?.cancel();
      _compactTimer = null;
    } else {
      _schedule();
    }
  }

  bool _scrubbing = false;
  int _controlsRevision = 0;
  bool? _hiddenAtPointerDown;
  final Set<int> _pointers = {};
  _HoldSpeedSession? _holdSession;
  LumioSource? _source;

  int? _index;
  LumioPlaybackEngine? _engine;
  double _zoom = 1, _startZoom = 1;
  Offset _pan = Offset.zero, _anchor = Offset.zero;
  Size _viewport = Size.zero;
  bool _fullscreenRouteActive = false;
  Size? _inlineSize;

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
    _compacted = widget.compactedController?.value ?? false;
    widget.compactedController?.addListener(_presentationChanged);
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
    if (oldWidget.compactedController != widget.compactedController) {
      oldWidget.compactedController?.removeListener(_presentationChanged);
      widget.compactedController?.addListener(_presentationChanged);
      _compacted = widget.compactedController?.value ?? _compacted;
    }
    if (oldWidget.controller != _controller ||
        oldWidget.controls != widget.controls ||
        oldWidget.controlsConfiguration.enabled != _config.enabled) {
      _controlsRevision++;
      _interacting = false;
      _scrubbing = false;
    }
    if (widget.fit != null &&
        (oldWidget.fit != widget.fit || oldWidget.controller != _controller)) {
      unawaited(
        _run(null, _controller, () => _controller.setVideoFit(widget.fit!)),
      );
    }
    if (oldWidget.controller != _controller) {
      _resetSeekFeedback();
      _endHold();
      oldWidget.controller.removeListener(_changed);
      _controller.addListener(_changed);
      _source = _controller.source;
      _index = _controller.playlistIndex;
      _engine = _controller.value.engine;
      _resetZoom();
    }
    if (!_enabled ||
        !_config.doubleTapSeek ||
        oldWidget.controlsConfiguration.seekInterval != _config.seekInterval) {
      _resetSeekFeedback();
    }
    if (!_enabled || !_config.holdToSpeed) _endHold();
    if (!_enabled || !_config.enableZoom) _resetZoom();
    if (oldWidget.controls != widget.controls ||
        oldWidget.controlsConfiguration.enabled != _config.enabled ||
        oldWidget.controlsConfiguration.compact != _config.compact) {
      _hidden = false;
      _schedule();
    }
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
    if (sourceChanged || _engine != state.engine || !_seekable(_controller)) {
      _scrubbing = false;
      _resetSeekFeedback();
    }
    if (sourceChanged) _resetZoom();
    _source = _controller.source;
    _index = _controller.playlistIndex;
    _engine = state.engine;
    // Playback notifications do not override the user's presentation choice,
    // including pause, completion and loading between independent sources.
    if (state.error != null) _hidden = false;
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

  void _scrubbingChanged(bool active) {
    if (!mounted || _scrubbing == active) return;
    setState(() => _scrubbing = active);
  }

  void _interaction(bool active) {
    if (!mounted) return;
    _interacting = active;
    _reveal();
  }

  void _toggleCompact() {
    final wasHidden = _hiddenAtPointerDown ?? _hidden;
    _hiddenAtPointerDown = null;
    if (!_config.compact ||
        !_ready(_controller.value) ||
        _controller.value.buffering) {
      _reveal();
      return;
    }
    setState(() => _hidden = !wasHidden);
    if (_hidden) {
      _compactTimer?.cancel();
      _compactTimer = null;
    } else {
      _schedule();
    }
  }

  void _resetSeekFeedback() {
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = null;
    _seekFeedback = Duration.zero;
    _doubleTapForward = null;
  }

  void _scheduleSeekFeedbackExpiry() {
    _seekFeedbackTimer?.cancel();
    _seekFeedbackTimer = null;
    if (_seekFeedback == Duration.zero || _pointers.isNotEmpty) return;
    _seekFeedbackTimer = Timer(const Duration(milliseconds: 900), () {
      if (mounted) setState(_resetSeekFeedback);
    });
  }

  void _confirmDoubleTap() {
    final forward = _doubleTapForward;
    _doubleTapForward = null;
    if (forward == null ||
        !_enabled ||
        !_config.doubleTapSeek ||
        !_seekable(_controller)) {
      return;
    }
    final delta = forward ? _config.seekInterval : -_config.seekInterval;
    setState(() {
      final sameDirection =
          _seekFeedback != Duration.zero &&
          _seekFeedback.isNegative == delta.isNegative;
      _seekFeedback = sameDirection ? _seekFeedback + delta : delta;
    });
    _reveal();
    _scheduleSeekFeedbackExpiry();
    unawaited(_skip(context, _controller, delta));
  }

  void _beginHold() {
    if (!_enabled ||
        !_config.holdToSpeed ||
        _pointers.length > 1 ||
        !_ready(_controller.value) ||
        _live(_controller) ||
        (_controller.value.speed != 1 && _controller.value.speed < 2) ||
        _holdSession != null) {
      return;
    }
    _resetSeekFeedback();
    _holding = true;
    final session = _HoldSpeedSession(
      _controller,
      _controller.value.speed == 1 ? _config.holdSpeed : 1,
    );
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
    _disposing = true;
    widget.compactedController?.removeListener(_presentationChanged);
    _resetSeekFeedback();
    _compactTimer?.cancel();
    _controller.removeListener(_changed);
    _endHold();
    // _endHold may schedule a new timer while the old state is still mounted.
    _compactTimer?.cancel();
    super.dispose();
  }

  Future<void> _openFullscreen() async {
    if (_fullscreenRouteActive || widget.isFullscreen) return;
    final navigator = Navigator.of(context);
    final renderObject = context.findRenderObject();
    if (renderObject is RenderBox && renderObject.hasSize) {
      _inlineSize = renderObject.size;
    }
    _endHold();
    setState(() => _fullscreenRouteActive = true);
    try {
      // Dispose the inline platform view before mounting its fullscreen owner.
      await WidgetsBinding.instance.endOfFrame;
      if (!mounted) return;
      final route = MaterialPageRoute<void>(
        fullscreenDialog: true,
        builder: (routeContext) => Scaffold(
          backgroundColor: Colors.black,
          body: SafeArea(
            child: LumioPlayerView(
              controller: _controller,
              controls: widget.controls,
              controlsConfiguration: _config,
              compactedController: widget.compactedController,
              title: widget.title,
              fit: widget.fit,
              layout: LumioVideoLayout.expand,
              placeholder: widget.placeholder,
              errorBuilder: widget.errorBuilder,
              surfaceCaptureKey: widget.surfaceCaptureKey,
              mediaWrapper: widget.mediaWrapper,
              isFullscreen: true,
              onToggleFullscreen: () => Navigator.of(routeContext).pop(),
            ),
          ),
        ),
      );
      await navigator.push<void>(route);
      // The pop future resolves before the outgoing route is unmounted.
      await route.completed;
    } finally {
      if (mounted) {
        setState(() {
          _fullscreenRouteActive = false;
          _hidden = false;
        });
        _schedule();
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    if (_fullscreenRouteActive) {
      return SizedBox(width: _inlineSize?.width, height: _inlineSize?.height);
    }
    final state = _controller.value;
    final web = _controller.webViewController;
    final texture = _controller.textureId;
    final audio = _controller.configuration.mode == LumioPlaybackMode.audio;
    final live =
        _live(_controller) || _config.layout == LumioControlsLayout.live;
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
        final surface = LayoutBuilder(
          builder: (context, constraints) {
            _viewport = constraints.biggest;
            return Listener(
              onPointerDown: _enabled
                  ? (event) {
                      if (_pointers.isEmpty) _hiddenAtPointerDown = _hidden;
                      _pointers.add(event.pointer);
                      _seekFeedbackTimer?.cancel();
                      _seekFeedbackTimer = null;
                      if (_pointers.length > 1) _endHold();
                      _interaction(true);
                    }
                  : null,
              onPointerUp: _enabled
                  ? (event) {
                      _pointers.remove(event.pointer);
                      _endHold();
                      if (_pointers.isEmpty) {
                        _interaction(false);
                        _scheduleSeekFeedbackExpiry();
                      }
                    }
                  : null,
              onPointerCancel: _enabled
                  ? (event) {
                      _pointers.remove(event.pointer);
                      _endHold();
                      if (_pointers.isEmpty) {
                        _interaction(false);
                        _scheduleSeekFeedbackExpiry();
                      }
                    }
                  : null,
              child: GestureDetector(
                key: const ValueKey('lumio-gesture-surface'),
                behavior: HitTestBehavior.opaque,
                onTap: _enabled ? _toggleCompact : null,
                onDoubleTapDown: _enabled && !live && _config.doubleTapSeek
                    ? (details) {
                        _doubleTapForward =
                            details.localPosition.dx >= _viewport.width / 2;
                      }
                    : null,
                onDoubleTap: _enabled && !live && _config.doubleTapSeek
                    ? _confirmDoubleTap
                    : null,
                onDoubleTapCancel: _enabled && !live && _config.doubleTapSeek
                    ? () => _doubleTapForward = null
                    : null,
                onLongPressStart: _enabled && !live && _config.holdToSpeed
                    ? (_) => _beginHold()
                    : null,
                onLongPressEnd: _enabled && !live && _config.holdToSpeed
                    ? (_) {
                        _endHold();
                        _reveal();
                      }
                    : null,
                onLongPressCancel: _enabled && !live && _config.holdToSpeed
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
                                widget.placeholder?.call(context, state) ??
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
                          !(_scrubbing &&
                              _enabled &&
                              _config.showProgress &&
                              _config.previewWhileScrubbing &&
                              _config.layout != LumioControlsLayout.live &&
                              _seekable(_controller)) &&
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
                                    style: const TextStyle(color: Colors.white),
                                  ),
                                ),
                              ),
                        ),
                      if (_enabled &&
                          _config.compact &&
                          _hidden &&
                          !audio &&
                          !live &&
                          _ready(state) &&
                          !state.playing &&
                          !state.buffering &&
                          !state.completed)
                        Positioned(
                          left: 0,
                          right: 0,
                          bottom: 16,
                          child: IgnorePointer(
                            child: Center(
                              child: Semantics(
                                label: _config.pausedLabel,
                                child: DecoratedBox(
                                  key: const ValueKey('lumio-compact-paused'),
                                  decoration: BoxDecoration(
                                    color: Colors.black.withValues(alpha: .55),
                                    shape: BoxShape.circle,
                                  ),
                                  child: const Padding(
                                    padding: EdgeInsets.all(8),
                                    child: Icon(
                                      Icons.pause_rounded,
                                      size: 28,
                                      color: Colors.white,
                                    ),
                                  ),
                                ),
                              ),
                            ),
                          ),
                        ),
                      if (_seekFeedback != Duration.zero)
                        IgnorePointer(
                          child: Align(
                            alignment: _seekFeedback.isNegative
                                ? Alignment.centerLeft
                                : Alignment.centerRight,
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: _GestureFeedbackPill(
                                key: const ValueKey('lumio-seek-feedback'),
                                label:
                                    '${_seekFeedback.isNegative ? '-' : '+'}${_seekFeedback.inSeconds.abs()}s',
                                icon: _seekFeedback.isNegative
                                    ? Icons.fast_rewind_rounded
                                    : Icons.fast_forward_rounded,
                                trailingIcon: !_seekFeedback.isNegative,
                                semanticsLabel:
                                    '${_seekFeedback.isNegative ? 'Retroceder' : 'Avançar'} ${_seekFeedback.inSeconds.abs()} segundos',
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
                              child: _GestureFeedbackPill(
                                key: const ValueKey(
                                  'lumio-hold-speed-feedback',
                                ),
                                labelKey: const ValueKey(
                                  'lumio-hold-speed-label',
                                ),
                                label: _speedLabel(_holdSession!.speed),
                                icon: Icons.speed_rounded,
                                semanticsLabel:
                                    'Velocidade temporária ${_speedLabel(_holdSession!.speed)}',
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
        );
        final media = widget.mediaWrapper?.call(context, surface) ?? surface;
        final controlsRevision = _controlsRevision;
        final controls = _enabled
            ? LumioPlayerControls(
                controller: _controller,
                configuration: _config,
                title: widget.title,
                compacted: _hidden,
                onInteraction: (active) {
                  if (mounted && controlsRevision == _controlsRevision) {
                    _interaction(active);
                  }
                },
                onScrubbingChanged: (active) {
                  if (mounted && controlsRevision == _controlsRevision) {
                    _scrubbingChanged(active);
                  }
                },
                beforeCommand: _endHold,
                isFullscreen: widget.isFullscreen,
                onToggleFullscreen:
                    widget.onToggleFullscreen ??
                    () =>
                        unawaited(_run(context, _controller, _openFullscreen)),
              )
            : const SizedBox.shrink();
        final overlay = _config.placement == LumioControlsPlacement.overlay;
        return Column(
          mainAxisSize: widget.layout == LumioVideoLayout.expand
              ? MainAxisSize.max
              : MainAxisSize.min,
          children: [
            _surfaceFrame(
              child: Stack(
                fit: StackFit.expand,
                children: [
                  if (widget.surfaceCaptureKey != null)
                    RepaintBoundary(key: widget.surfaceCaptureKey, child: media)
                  else
                    media,
                  if (_enabled && overlay)
                    Positioned(
                      key: const ValueKey('lumio-controls-overlay'),
                      left: 0,
                      right: 0,
                      bottom: 0,
                      child: controls,
                    ),
                ],
              ),
            ),
            if (_enabled && !overlay)
              KeyedSubtree(
                key: const ValueKey('lumio-controls-below'),
                child: controls,
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
/// Scrubbing is local until release by default; opt-in previews seek while
/// dragging. Position events cannot move the thumb during a drag.
/// All asynchronous command failures are safely handled.
class LumioPlayerControls extends StatefulWidget {
  const LumioPlayerControls({
    super.key,
    required this.controller,
    this.configuration = const LumioControlsConfiguration(),
    this.title,
    this.compacted = false,
    this.onInteraction,
    this.onScrubbingChanged,
    this.beforeCommand,
    this.onToggleFullscreen,
    this.isFullscreen = false,
  });

  final LumioPlayerController controller;
  final LumioControlsConfiguration configuration;
  final String? title;
  final bool compacted;
  final ValueChanged<bool>? onInteraction;

  /// Reports an opt-in preview session, including its final seek and cleanup.
  /// The player view uses this to suppress the loader over scrubbed frames.
  final ValueChanged<bool>? onScrubbingChanged;
  final VoidCallback? beforeCommand;
  final VoidCallback? onToggleFullscreen;
  final bool isFullscreen;
  static const playbackSpeeds = <double>[1, 2, 3, 4];

  @override
  State<LumioPlayerControls> createState() => _LumioPlayerControlsState();
}

/// Owns only commands for one media identity. A timer opens a throttle window;
/// moves replace the pending target rather than restarting that timer.
/// Command completion can be an acceptance ACK, not decoded-frame readiness.
class _ScrubPreviewSession {
  // Values are tokens only: ownership must not retain a State or controller.
  static final Expando<Object> _owners = Expando<Object>();
  final Object _token = Object();

  _ScrubPreviewSession({
    required this.controller,
    required this.interval,
    required this.wasPlaying,
    required this.owns,
    required this.canRestore,
    required this.run,
    Future<void>? previous,
  }) : source = controller.source,
       index = controller.playlistIndex,
       engine = controller.value.engine,
       requestedEngine = controller.requestedEngine {
    _owners[controller] = _token;
    _pending = _pause(previous);
  }

  final LumioPlayerController controller;
  final Duration interval;
  final bool wasPlaying;
  final bool Function() owns, canRestore;
  final Future<bool> Function(Future<void> Function()) run;
  final LumioSource? source;
  final int index;
  final LumioPlaybackEngine engine, requestedEngine;
  Timer? _timer;
  Future<void>? _pending, _observedPending;
  Duration? _desired;
  bool _cancelled = false, _ending = false, _pauseOK = true;
  bool _paused = false;

  bool get sameMedia =>
      identical(source, controller.source) &&
      index == controller.playlistIndex &&
      engine == controller.value.engine &&
      requestedEngine == controller.requestedEngine &&
      _ready(controller.value);
  bool get _ownsController => identical(_owners[controller], _token);
  bool get valid =>
      !_cancelled &&
      _ownsController &&
      owns() &&
      sameMedia &&
      _seekable(controller);
  bool get _mayRestore =>
      _ownsController && canRestore() && sameMedia && _paused;

  Future<void> _pause(Future<void>? previous) async {
    await (previous ?? Future<void>.value());
    if (valid && wasPlaying) {
      _pauseOK = await run(() => controller.pause(isCurrent: () => valid));
      _paused = _pauseOK;
    }
  }

  void move(Duration target) {
    if (!valid || _ending) return;
    _desired = target;
    _pump();
  }

  void _pump() {
    if (!valid || _ending || _timer != null || _desired == null) return;
    final pending = _pending;
    if (pending != null) {
      _observePending(pending);
      return;
    }
    if (!_pauseOK) return;
    final target = _desired!;
    _desired = null;
    _timer = Timer(interval, () {
      _timer = null;
      _pump();
    });
    final seek = run(
      () => controller.seekToPreview(_bounded(target), isCurrent: () => valid),
    ).then<void>((_) {});
    _pending = seek;
    _observePending(seek);
  }

  void _observePending(Future<void> pending) {
    if (identical(_observedPending, pending)) return;
    _observedPending = pending;
    unawaited(
      pending.then((_) {
        if (identical(_observedPending, pending)) _observedPending = null;
        if (identical(_pending, pending)) _pending = null;
        _pump();
      }),
    );
  }

  Future<void> finish(Duration target) {
    final previous = _pending;
    final finishing = _finish(target, previous);
    _pending = finishing;
    return finishing;
  }

  Future<void> _finish(Duration target, Future<void>? previous) async {
    _ending = true;
    _timer?.cancel();
    _timer = null;
    _desired = null;
    await previous;
    if (!valid || !_pauseOK) return;
    final success = await run(
      () => controller.seekToPreview(_bounded(target), isCurrent: () => valid),
    );
    if (success && valid && wasPlaying) {
      await run(() => controller.play(isCurrent: () => valid));
    }
  }

  Duration _bounded(Duration target) => Duration(
    milliseconds: target.inMilliseconds.clamp(
      0,
      controller.value.duration.inMilliseconds,
    ),
  );

  Future<void>? _cancellation;

  Future<void> cancel({bool restore = true}) =>
      _cancellation ??= _cancel(restore: restore);

  Future<void> _cancel({required bool restore}) async {
    _cancelled = true;
    _timer?.cancel();
    _timer = null;
    _desired = null;
    await _pending;
    // A superseding drag inherits the original playback intent instead.
    if (restore && _mayRestore) {
      await run(() => controller.play(isCurrent: () => _mayRestore));
    }
  }
}

class _LumioPlayerControlsState extends State<LumioPlayerControls> {
  double? _drag;
  LumioSource? _dragSource;
  int? _dragIndex;
  double _lastVolume = 1;
  bool _dragging = false;
  bool _interactionActive = false, _scrubbingActive = false;

  void _notifyInteraction(bool active) {
    _interactionActive = active;
    widget.onInteraction?.call(active);
  }

  void _notifyScrubbing(bool active, {bool force = false}) {
    if (!force && _scrubbingActive == active) return;
    _scrubbingActive = active;
    widget.onScrubbingChanged?.call(active);
  }

  _ScrubPreviewSession? _preview;

  bool get _previewEnabled =>
      _config.enabled &&
      _config.showProgress &&
      _config.previewWhileScrubbing &&
      _config.layout != LumioControlsLayout.live &&
      _seekable(_controller);

  @override
  void initState() {
    super.initState();
    _controller.addListener(_observeScrub);
  }

  void _observeScrub() {
    final session = _preview;
    if (session != null && (!session.sameMedia || !_previewEnabled)) {
      _cancelScrub();
    }
  }

  void _cancelScrub() {
    final session = _preview;
    if (session == null) return;
    _dragging = false;
    _drag = null;
    unawaited(
      session.cancel().then((_) {
        if (!identical(_preview, session)) return;
        _preview = null;
        if (mounted) {
          setState(() {});
          // Cancellation can originate in didUpdateWidget or unmount.
          WidgetsBinding.instance.addPostFrameCallback((_) {
            if (mounted && _preview == null && !_dragging) {
              _notifyScrubbing(false);
              _menuClosed();
            }
          });
        }
      }),
    );
  }

  void _startScrub(double value) {
    final previous = _preview;
    _dragging = true;
    _dragSource = _controller.source;
    _dragIndex = _controller.playlistIndex;
    _notifyInteraction(true);
    if (!_previewEnabled) return;
    // The parent may have reset its flag on a media/controller change while
    // this State is still waiting for the previous session's cancellation.
    _notifyScrubbing(true, force: true);
    widget.beforeCommand?.call();
    final inherited =
        previous != null &&
        identical(previous.controller, _controller) &&
        previous.sameMedia &&
        previous.wasPlaying;
    final barrier = previous?.cancel(restore: false);
    final controller = _controller;
    late final _ScrubPreviewSession session;
    session = _ScrubPreviewSession(
      controller: controller,
      interval: _config.scrubPreviewInterval,
      wasPlaying: inherited || controller.value.playing,
      owns: () => identical(_preview, session),
      canRestore: () =>
          identical(_preview, session) ||
          !identical(_preview?.controller, controller),
      run: (command) =>
          _runResult(mounted ? context : null, controller, command),
      previous: barrier,
    );
    _preview = session;
  }

  Future<void> _endScrub(double value) async {
    _dragging = false;
    final session = _preview;
    if (session != null) {
      await session.finish(Duration(milliseconds: value.round()));
      if (!mounted || !identical(_preview, session)) return;
      _preview = null;
      setState(() => _drag = null);
      _notifyScrubbing(false);
      _menuClosed();
      return;
    }
    final controller = _controller;
    final sameItem =
        identical(_dragSource, controller.source) &&
        _dragIndex == controller.playlistIndex;
    setState(() => _drag = null);
    if (sameItem && _seekable(controller)) {
      await _command(
        () => controller.seekTo(
          Duration(
            milliseconds: value.round().clamp(
              0,
              controller.value.duration.inMilliseconds,
            ),
          ),
        ),
      );
    } else {
      _menuClosed();
    }
  }

  @override
  void dispose() {
    _controller.removeListener(_observeScrub);
    final session = _preview;
    if (session != null) unawaited(session.cancel());
    final interaction = _interactionActive ? widget.onInteraction : null;
    final scrubbing = _scrubbingActive ? widget.onScrubbingChanged : null;
    // Unmount happens during ancestor build. Never call its setState here.
    WidgetsBinding.instance.addPostFrameCallback((_) {
      scrubbing?.call(false);
      interaction?.call(false);
    });
    super.dispose();
  }

  LumioPlayerController get _controller => widget.controller;
  LumioControlsConfiguration get _config => widget.configuration;
  Color get _backgroundColor =>
      _config.placement == LumioControlsPlacement.overlay
      ? _config.backgroundColor.withValues(
          alpha: _config.backgroundColor.a * .65,
        )
      : _config.backgroundColor;

  Future<void> _command(Future<void> Function() command) async {
    widget.beforeCommand?.call();
    _notifyInteraction(true);
    try {
      await _run(context, _controller, command);
    } finally {
      if (mounted) _notifyInteraction(false);
    }
  }

  void _menuOpened() => _notifyInteraction(true);
  void _menuClosed() => _notifyInteraction(false);

  @override
  void didUpdateWidget(LumioPlayerControls oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != _controller) {
      oldWidget.controller.removeListener(_observeScrub);
      _controller.addListener(_observeScrub);
      _cancelScrub();
      _drag = null;
      _dragging = false;
    } else if (!_previewEnabled) {
      _cancelScrub();
    }
  }

  @override
  Widget build(BuildContext context) {
    _config.validate();
    if (!_config.enabled) return const SizedBox.shrink();
    return LayoutBuilder(
      builder: (context, controlsConstraints) =>
          ValueListenableBuilder<LumioPlayerState>(
            valueListenable: _controller,
            builder: (context, state, _) {
              final enabled = _ready(state);
              final live =
                  _live(_controller) ||
                  _config.layout == LumioControlsLayout.live;
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
                  _config.progressColor ??
                  Theme.of(context).colorScheme.primary;
              final title =
                  widget.title ??
                  _controller.title ??
                  _controller.currentItem?.title;
              final simplified =
                  !live && _config.layout == LumioControlsLayout.simplified;
              final fullscreenOverlay =
                  widget.isFullscreen &&
                  _config.placement == LumioControlsPlacement.overlay;
              final horizontalPadding = fullscreenOverlay
                  ? (controlsConstraints.maxWidth * 0.03).clamp(20.0, 40.0)
                  : live
                  ? (controlsConstraints.maxWidth >= 400 ? 20.0 : 8.0)
                  : 12.0;
              final safePadding = fullscreenOverlay
                  ? MediaQuery.paddingOf(context)
                  : EdgeInsets.zero;
              final contentPadding = EdgeInsets.fromLTRB(
                horizontalPadding + safePadding.left,
                8,
                horizontalPadding + safePadding.right,
                8,
              );
              final availableWidth =
                  (controlsConstraints.maxWidth - contentPadding.horizontal)
                      .clamp(0.0, double.infinity);
              final actionCount = live
                  ? (_config.showVolume ? 1 : 0) +
                        (_config.showFullscreen &&
                                widget.onToggleFullscreen != null
                            ? 1
                            : 0)
                  : simplified
                  ? 2
                  : (_config.showPlayPause ? 1 : 0) +
                        (_config.showSkipButtons ? 2 : 0) +
                        (_config.showVolume ? 1 : 0) +
                        (_config.showSpeed ? 1 : 0) +
                        (_config.showPlaylistNavigation &&
                                _controller.playlist != null
                            ? (_config.showPreviousItem ? 1 : 0) +
                                  (_config.showNextItem ? 1 : 0)
                            : 0) +
                        (_config.showFullscreen &&
                                widget.onToggleFullscreen != null
                            ? 1
                            : 0);
              final buttonExtent = actionCount > 0
                  ? (availableWidth / actionCount).clamp(32.0, 40.0)
                  : 40.0;
              Widget button(
                String tooltip,
                IconData icon,
                VoidCallback? action,
              ) => SizedBox(
                width: buttonExtent,
                height: 40,
                child: IconButton(
                  tooltip: tooltip,
                  icon: Icon(icon),
                  iconSize: (buttonExtent * .6).clamp(18.0, 24.0),
                  padding: EdgeInsets.zero,
                  constraints: const BoxConstraints(),
                  style: const ButtonStyle(
                    minimumSize: WidgetStatePropertyAll(Size.zero),
                    tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                  ),
                  onPressed: action,
                ),
              );
              if (widget.compacted) {
                return Material(
                  color: _backgroundColor,
                  child: GestureDetector(
                    key: const ValueKey('lumio-compact-controls'),
                    behavior: HitTestBehavior.opaque,
                    onTap: () {
                      _notifyInteraction(true);
                      _menuClosed();
                    },
                    child: SizedBox(
                      height:
                          _config.placement == LumioControlsPlacement.overlay
                          ? 4
                          : 6,
                      child: Align(
                        alignment:
                            _config.placement == LumioControlsPlacement.overlay
                            ? Alignment.bottomCenter
                            : Alignment.topCenter,
                        child: _config.showProgress && !live
                            ? LinearProgressIndicator(
                                key: const ValueKey('lumio-compact-progress'),
                                minHeight:
                                    _config.placement ==
                                        LumioControlsPlacement.overlay
                                    ? 4
                                    : 2,
                                color: accent,
                                backgroundColor: _config.foregroundColor
                                    .withValues(alpha: .15),
                                value: duration > 0 ? progress / duration : 0,
                              )
                            : const SizedBox.shrink(),
                      ),
                    ),
                  ),
                );
              }
              final progressWidget = SliderTheme(
                data: SliderTheme.of(context).copyWith(
                  activeTrackColor: accent,
                  thumbColor: _config.foregroundColor,
                  thumbShape: const RoundSliderThumbShape(
                    enabledThumbRadius: 7,
                  ),
                  trackShape: const RectangularSliderTrackShape(),
                  trackGap: 0,
                  inactiveTrackColor: _config.foregroundColor.withValues(
                    alpha: .2,
                  ),
                  trackHeight: 4,
                ),
                child: Listener(
                  onPointerCancel: (_) => _cancelScrub(),
                  child: Slider(
                    key: const ValueKey('lumio-progress'),
                    padding: EdgeInsets.zero,
                    value: progress,
                    max: duration > 0 ? duration : 1,
                    label: _time(Duration(milliseconds: progress.round())),
                    semanticFormatterCallback: (value) =>
                        _time(Duration(milliseconds: value.round())),
                    onChangeStart: seekable ? _startScrub : null,
                    onChanged: seekable
                        ? (value) {
                            // Accessibility changes have no start/end callbacks.
                            if (!_dragging && _previewEnabled) {
                              _startScrub(value);
                              setState(() => _drag = value);
                              unawaited(_endScrub(value));
                            } else {
                              _dragSource ??= _controller.source;
                              _dragIndex ??= _controller.playlistIndex;
                              setState(() => _drag = value);
                              _preview?.move(
                                Duration(milliseconds: value.round()),
                              );
                            }
                          }
                        : null,
                    onChangeEnd: seekable
                        ? (value) => unawaited(_endScrub(value))
                        : null,
                  ),
                ),
              );
              final speedWidget = Tooltip(
                message: 'Playback speed',
                child: SizedBox(
                  width: buttonExtent,
                  height: 40,
                  child: TextButton(
                    onPressed: enabled && !live
                        ? () => _command(() {
                            final speeds = _config.playbackSpeeds;
                            final index = speeds.indexOf(
                              _controller.value.speed,
                            );
                            return _controller.setSpeed(
                              speeds[(index + 1) % speeds.length],
                            );
                          })
                        : null,
                    onLongPress: enabled && !live
                        ? () => _command(() => _controller.setSpeed(1))
                        : null,
                    style: TextButton.styleFrom(
                      foregroundColor: _config.foregroundColor,
                      padding: const EdgeInsets.symmetric(horizontal: 4),
                      minimumSize: Size.zero,
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    child: FittedBox(
                      fit: BoxFit.scaleDown,
                      child: Text(
                        _speedLabel(state.speed),
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          fontSize: 16,
                        ),
                      ),
                    ),
                  ),
                ),
              );
              final volumeWidgets = <Widget>[
                if (_config.showVolume) ...[
                  button(
                    state.volume == 0 ? 'Unmute' : 'Mute',
                    state.volume == 0 ? Icons.volume_off : Icons.volume_up,
                    enabled
                        ? () {
                            if (state.volume > 0) {
                              _lastVolume = state.volume;
                            }
                            _command(
                              () => _controller.setVolume(
                                state.volume == 0
                                    ? (_controller.capabilities.volumeControl
                                          ? _lastVolume
                                          : 1)
                                    : 0,
                              ),
                            );
                          }
                        : null,
                  ),
                ],
              ];
              final volumeSlider =
                  !live &&
                      !simplified &&
                      _config.showVolume &&
                      _config.showVolumeSlider &&
                      _controller.capabilities.volumeControl
                  ? SizedBox(
                      width: 100,
                      child: Slider(
                        key: const ValueKey('lumio-volume'),
                        value: state.volume.clamp(0, 1),
                        semanticFormatterCallback: (value) =>
                            'Volume ${(value * 100).round()}%',
                        onChangeStart: enabled ? (_) => _menuOpened() : null,
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
                        onChangeEnd: enabled ? (_) => _menuClosed() : null,
                      ),
                    )
                  : null;
              final playButton = button(
                state.playing ? 'Pause' : 'Play',
                state.playing ? Icons.pause : Icons.play_arrow_outlined,
                enabled
                    ? () => _command(
                        state.playing ? _controller.pause : _controller.play,
                      )
                    : null,
              );
              final fullscreenButton =
                  _config.showFullscreen && widget.onToggleFullscreen != null
                  ? button(
                      widget.isFullscreen ? 'Exit fullscreen' : 'Fullscreen',
                      widget.isFullscreen
                          ? Icons.fullscreen_exit
                          : Icons.fullscreen,
                      () {
                        widget.beforeCommand?.call();
                        _notifyInteraction(false);
                        widget.onToggleFullscreen?.call();
                      },
                    )
                  : null;
              Widget metadata() {
                if (!_config.showStatus && !_config.showTime) {
                  return const SizedBox.shrink();
                }
                return LayoutBuilder(
                  builder: (context, constraints) => Row(
                    key: const ValueKey('lumio-progress-row'),
                    children: [
                      Expanded(
                        child: _config.showStatus
                            ? Text(
                                _scrubbingActive
                                    ? _config.pausedLabel
                                    : state.buffering || state.transitioning
                                    ? _config.loadingLabel
                                    : state.playing
                                    ? _config.playingLabel
                                    : _config.pausedLabel,
                                key: const ValueKey('lumio-playback-status'),
                                style: const TextStyle(fontSize: 11),
                                maxLines: 1,
                                overflow: TextOverflow.ellipsis,
                              )
                            : const SizedBox.shrink(),
                      ),
                      if (_config.showTime)
                        ConstrainedBox(
                          constraints: BoxConstraints(
                            maxWidth: constraints.maxWidth * .5,
                          ),
                          child: Text(
                            '${_time(Duration(milliseconds: progress.round()))} / ${_time(state.duration)}',
                            key: const ValueKey('lumio-progress-time'),
                            style: const TextStyle(fontSize: 11),
                            textWidthBasis: TextWidthBasis.longestLine,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                          ),
                        ),
                    ],
                  ),
                );
              }

              final timeline = Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  if (_config.showProgress) ...[
                    progressWidget,
                    const SizedBox(height: 8),
                  ],
                  metadata(),
                ],
              );
              final playlistButtons = <Widget>[
                if (!live &&
                    !simplified &&
                    _config.showPlaylistNavigation &&
                    _controller.playlist != null) ...[
                  if (_config.showPreviousItem)
                    button(
                      'Previous item',
                      Icons.skip_previous_outlined,
                      !state.transitioning && _controller.hasPrevious
                          ? () => _command(_controller.previous)
                          : null,
                    ),
                  if (_config.showNextItem)
                    button(
                      'Next item',
                      Icons.skip_next_outlined,
                      !state.transitioning && _controller.hasNext
                          ? () => _command(_controller.next)
                          : null,
                    ),
                ],
              ];
              final extras = <Widget>[
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
                        PopupMenuItem(value: engine, child: Text(engine.name)),
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
                        await LumioStatisticsView.show(context, _controller);
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
              ];
              final liveLabel = Text(
                _config.showTime && _config.showLiveTime
                    ? '${_config.liveLabel} · ${_time(state.position)}'
                    : _config.liveLabel,
                key: const ValueKey('lumio-live-status'),
                style: const TextStyle(fontWeight: FontWeight.w700),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
              );
              return Material(
                color: _backgroundColor,
                child: LayoutBuilder(
                  builder: (context, constraints) {
                    final wide = constraints.maxWidth >= 400;
                    return IconTheme(
                      data: IconThemeData(
                        color: _config.foregroundColor,
                        size: wide ? 32 : 24,
                      ),
                      child: DefaultTextStyle(
                        style: TextStyle(
                          color: _config.foregroundColor,
                          fontSize: wide ? 14 : 12,
                        ),
                        child: Padding(
                          padding: contentPadding,
                          child: Column(
                            mainAxisSize: MainAxisSize.min,
                            crossAxisAlignment: CrossAxisAlignment.stretch,
                            children: [
                              if (_config.showTitle &&
                                  title != null &&
                                  title.isNotEmpty)
                                Padding(
                                  padding: const EdgeInsets.only(bottom: 4),
                                  child: Text(
                                    title,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: _config.titleStyle,
                                  ),
                                ),
                              if (live)
                                Row(
                                  key: const ValueKey('lumio-live-layout'),
                                  children: [
                                    Expanded(
                                      child:
                                          _config.showStatus ||
                                              (_config.showTime &&
                                                  _config.showLiveTime)
                                          ? liveLabel
                                          : const SizedBox.shrink(),
                                    ),
                                    ...volumeWidgets,
                                    ?fullscreenButton,
                                  ],
                                )
                              else if (simplified)
                                Row(
                                  key: const ValueKey(
                                    'lumio-simplified-layout',
                                  ),
                                  children: [
                                    if (_config.showPlayPause) ...[
                                      playButton,
                                      const SizedBox(width: 8),
                                    ],
                                    Expanded(child: timeline),
                                    if (_config.simplifiedControl ==
                                            LumioSimplifiedControl.speed &&
                                        _config.showSpeed) ...[
                                      const SizedBox(width: 8),
                                      speedWidget,
                                    ],
                                    if (_config.simplifiedControl ==
                                            LumioSimplifiedControl.volume &&
                                        _config.showVolume) ...[
                                      const SizedBox(width: 8),
                                      ...volumeWidgets,
                                    ],
                                  ],
                                )
                              else ...[
                                timeline,
                                const SizedBox(height: 8),
                                Row(
                                  key: const ValueKey('lumio-complete-layout'),
                                  crossAxisAlignment: CrossAxisAlignment.center,
                                  children: [
                                    Expanded(
                                      child: SingleChildScrollView(
                                        scrollDirection: Axis.horizontal,
                                        child: Row(
                                          mainAxisSize: MainAxisSize.min,
                                          children: [
                                            if (_config.showPlayPause)
                                              playButton,
                                            if (_config.showSkipButtons) ...[
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
                                            ...volumeWidgets,
                                            if (_config.showSpeed) speedWidget,
                                            ...playlistButtons,
                                          ],
                                        ),
                                      ),
                                    ),
                                    ?fullscreenButton,
                                  ],
                                ),
                              ],
                              if (volumeSlider != null)
                                Align(
                                  alignment: Alignment.centerLeft,
                                  child: volumeSlider,
                                ),

                              if (extras.isNotEmpty)
                                Wrap(
                                  crossAxisAlignment: WrapCrossAlignment.center,
                                  children: extras,
                                ),
                            ],
                          ),
                        ),
                      ),
                    );
                  },
                ),
              );
            },
          ),
    );
  }
}
