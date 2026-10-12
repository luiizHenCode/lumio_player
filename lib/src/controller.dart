import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'startup_diagnostics.dart';
import 'failure_report.dart';
import 'native_bridge.dart';
import 'recovery_configuration.dart';
import 'web_engine.dart';

/// A player instance. Mount LumioPlayerView before awaiting WebView initialization.
/// Commands are serialized; dispose invalidates all outstanding engine events.
class LumioPlayerController extends ValueNotifier<LumioPlayerState>
    with WidgetsBindingObserver {
  LumioPlayerController({
    this.configuration = const LumioPlayerConfiguration(),
    this.recovery = const LumioRecoveryConfiguration(),
    this.logger,
    Map<String, String> httpHeaders = const {},
  }) : httpHeaders = Map.unmodifiable(httpHeaders),
       _requestedEngine = configuration.engine,
       _volume = configuration.volume,
       _speed = configuration.speed,
       _looping = configuration.looping,
       _wantsPlayback = configuration.autoPlay,
       super(
         LumioPlayerState(
           volume: configuration.volume,
           speed: configuration.speed,
         ),
       ) {
    configuration.validate();
    recovery.validate();
    final binding = WidgetsBinding.instance;
    _foreground = !_isBackground(binding.lifecycleState);
    binding.addObserver(this);
  }
  static int _nextPlayerId = 0;

  /// Stable identifier for correlating opening and disposal logs.
  final int playerId = ++_nextPlayerId;
  final LumioPlayerConfiguration configuration;
  final LumioRecoveryConfiguration recovery;
  final LumioLogger? logger;

  /// Default headers for network sources. Per-source/open headers take precedence.
  final Map<String, String> httpHeaders;
  final _bridge = LumioNativeBridge();
  LumioFailureReport? _lastFailure;
  LumioPlayerError? _recordedFailure;
  Future<void>? _failureDiagnostics;
  LumioStartupDiagnostics? _startup;
  int _startupAttempt = 0;
  int _selectionEpoch = 0;
  int? _nativeSelectionIndex;

  /// Safe, deeply immutable, monotonic attempt snapshot; null timings mean unknown.
  Map<String, Object?> get startupDiagnostics =>
      _startup?.snapshot ??
      const {
        'attempt': 0,
        'stage': 'idle',
        'evidence': null,
        'events': <Object?>[],
      };

  LumioPlaybackPhase get phase => value.phase;

  /// True only while a retry is actually pending or reopening the live source.
  /// A recoverable error alone does not imply that recovery will be attempted.
  bool get isRecovering =>
      !_disposed &&
      (_recoveryTimer != null ||
          _recoveryQueued ||
          _recoveryInProgress ||
          (_startup?.recovering == true && value.transitioning));

  bool _awaitingFirstFrame(LumioPlayerState state) =>
      configuration.mode != LumioPlaybackMode.audio &&
      _effectivePlayback &&
      state.initialized &&
      state.firstFrameSupported &&
      !state.hasRenderedFirstFrame &&
      !state.completed &&
      state.error == null;

  /// Presentation only: never used for command readiness or recovery watchdogs.
  bool get awaitingFirstFrame => _awaitingFirstFrame(value);

  void _beginStartup({bool recovering = false, Stopwatch? clock}) {
    _startup = LumioStartupDiagnostics(
      ++_startupAttempt,
      recovering: recovering,
      clock: clock,
    );
  }

  LumioPlaybackPhase _phaseFor(LumioPlayerState state) {
    if (state.error != null) return LumioPlaybackPhase.failed;
    if (_startup?.recovering == true && state.transitioning) {
      return LumioPlaybackPhase.recovering;
    }
    if (!state.initialized) {
      if (_startup == null) return LumioPlaybackPhase.idle;
      return _startup!.createElapsedMs == null
          ? LumioPlaybackPhase.connecting
          : LumioPlaybackPhase.preparing;
    }
    if (_awaitingFirstFrame(state)) return LumioPlaybackPhase.ready;
    if (state.buffering) return LumioPlaybackPhase.buffering;
    return state.playing
        ? LumioPlaybackPhase.playing
        : LumioPlaybackPhase.ready;
  }

  @override
  set value(LumioPlayerState state) {
    state = state.copyWith(phase: _phaseFor(state));
    if (!_disposed) _startup?.observe(state);
    final error = state.error;
    if (!_disposed && error != null && !identical(error, _recordedFailure)) {
      _recordFailure(error, state: state);
    }
    if (error == null) _recordedFailure = null;
    super.value = state;
  }

  /// Returns the current/last failure, or null if no failure was observed.
  /// Safe after disposal; never queries a replacement engine for an old failure.
  Future<LumioFailureReport?> failureReport() async {
    if (!_disposed) {
      Future<void>? pending;
      do {
        pending = _failureDiagnostics;
        await pending;
      } while (!_disposed && !identical(pending, _failureDiagnostics));
    }
    return _lastFailure;
  }

  void _recordFailure(
    LumioPlayerError error, {
    LumioPlayerState? state,
    Object? details,
  }) {
    if (_disposed || identical(error, _recordedFailure)) return;
    _recordedFailure = error;
    _startup?.stage(LumioPlaybackPhase.failed);
    final playback = state ?? value;
    final report = LumioFailureReport(
      timestamp: DateTime.now().toUtc(),
      code: safeFailureCode(error.code),
      message: 'Playback failed. See the failure code and safe diagnostics.',
      metadata: {
        'startup': startupDiagnostics,
        'engine': (error.engine ?? playback.engine).name,
        'requestedEngine': _requestedEngine.name,
        'platform': kIsWeb ? 'web' : defaultTargetPlatform.name,
        'recoverable': error.recoverable,
        'fallbackUsed': _fallbackUsed,
        'configuration': {
          'mode': configuration.mode.name,
          ...configuration.toMap(),
          'allowAutomaticFallback': configuration.allowAutomaticFallback,
        },
        'recovery': {
          'enabled': recovery.enabled,
          'attempts': _attempts,
          'maxAttempts': recovery.maxAttempts,
          'initialDelayMs': recovery.initialDelay.inMilliseconds,
          'maxDelayMs': recovery.maxDelay.inMilliseconds,
          'stallTimeoutMs': recovery.stallTimeout.inMilliseconds,
          'stablePlaybackDurationMs':
              recovery.stablePlaybackDuration.inMilliseconds,
          'wantsPlayback': _wantsPlayback,
          'foreground': _foreground,
        },
        'playback': {
          ...safeFailureDiagnostics({
            'initialized': playback.initialized,
            'playing': playback.playing,
            'buffering': playback.buffering,
            'completed': playback.completed,
            'live': playback.live,
            'positionMs': playback.position.inMilliseconds,
            'durationMs': playback.duration.inMilliseconds,
            'bufferedPositionMs': playback.bufferedPosition.inMilliseconds,
            'width': playback.size.width,
            'height': playback.size.height,
            'speed': playback.speed,
            'volume': playback.volume,
            'playlistIndex': playback.playlistIndex,
            'playlistLength': playback.playlistLength,
          }),
          'sourceType': _source?.type.name,
          'formatHint': _source?.format.name,
          'fit': _videoFit.name,
        },
        'details': safeFailureDiagnostics(details ?? error.details),
        'native': <String, Object?>{},
        'diagnosticsStatus': 'unavailable',
      },
    );
    _lastFailure = report;
    final id = _id;
    final web = _web;
    final generation = _generation;
    // Defer the channel round trip out of the native event callback. Release
    // waits only for this bounded snapshot, never for unbounded native work.
    _failureDiagnostics = Future<void>(() async {
      if (_disposed ||
          generation != _generation ||
          (id == null && web == null)) {
        return;
      }
      try {
        final raw = web != null
            ? web.diagnostics
            : await _bridge
                  .invoke('diagnostics', id!)
                  .timeout(const Duration(milliseconds: 200));
        if (_disposed || !identical(_lastFailure, report)) return;
        _lastFailure = LumioFailureReport(
          timestamp: report.timestamp,
          code: report.code,
          message: report.message,
          metadata: {
            ...report.metadata,
            'native': safeFailureDiagnostics(raw),
            'diagnosticsStatus': 'captured',
          },
        );
      } catch (_) {
        // Diagnostic errors must not replace the playback failure or leak text.
      }
    });
  }

  LumioSource? _source;
  LumioPlaylist? _playlist;
  int _playlistIndex = 0;
  String? _title;
  bool _webAdvanceQueued = false;
  LumioPlaybackEngine _requestedEngine;
  int? _id, _textureId;
  int _generation = 0;
  StreamSubscription<Map<String, dynamic>>? _subscription;
  LumioWebEngine? _web;
  Completer<void>? _ready;
  Completer<void>? _cancelPending;
  Future<void> _queue = Future.value();
  Future<void>? _disposal;
  bool _disposed = false, _fallbackUsed = false;
  int _pendingNativeCreations = 0, _pendingLateReleases = 0;
  bool _cleanupFailed = false, _closeFinished = false;
  bool _disposedLogged = false, _incompleteLogged = false;
  final _disposalWatch = Stopwatch();
  double _volume, _speed;
  BoxFit _videoFit = BoxFit.contain;
  BoxFit get videoFit => _videoFit;

  /// Presentation-only change: does not reopen the source or reset its position.
  Future<void> setVideoFit(BoxFit fit) async {
    if (_disposed) throw StateError('Player disposed.');
    final changed = _videoFit != fit;
    _videoFit = fit;
    if (changed) notifyListeners();
    final web = _web;
    if (web != null) await web.setFit(fit.name);
  }

  int _speedRevision = 0;

  /// Changes as soon as an explicit speed command is submitted, even if queued.
  int get speedRevision => _speedRevision;
  bool _looping;
  bool _wantsPlayback;
  bool _foreground = true;
  int _intentRevision = 0, _recoveryRevision = 0, _attempts = 0;
  Timer? _watchdog, _recoveryTimer;
  bool _recoveryQueued = false;
  bool _recoveryInProgress = false;
  Duration? _lastPosition;
  DateTime? _lastProgress, _stableSince;

  bool get _effectivePlayback =>
      _wantsPlayback && (_foreground || configuration.allowBackgroundPlayback);

  static bool _isBackground(AppLifecycleState? state) =>
      state == AppLifecycleState.hidden ||
      state == AppLifecycleState.paused ||
      state == AppLifecycleState.detached;

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_disposed || state == AppLifecycleState.inactive) return;
    final foreground = !_isBackground(state);
    if (_foreground == foreground) return;
    _foreground = foreground;
    _invalidateRecovery();
    value = value;
    final revision = _intentRevision;
    unawaited(
      _serialize(() async {
        if (revision != _intentRevision || _foreground != foreground) return;
        if (!configuration.allowBackgroundPlayback &&
            value.initialized &&
            !value.transitioning &&
            (!_foreground || value.error == null)) {
          await _command(_effectivePlayback ? 'play' : 'pause');
        }
        if (_foreground) {
          if (value.error != null) _scheduleRecovery(value.error!);
          _armWatchdog();
        }
      }).catchError((Object error) {
        if (!_disposed) {
          value = value.copyWith(error: _asError(error, value.engine));
        }
      }),
    );
  }

  Future<void> _changePlayback(
    Future<void> Function() action, {
    bool newSource = false,
  }) {
    _invalidateRecovery();
    if (newSource) {
      _attempts = 0;
      _wantsPlayback = configuration.autoPlay;
      ++_intentRevision;
    }
    return _serialize(() async {
      // An earlier queued open may have scheduled recovery since submission.
      _invalidateRecovery();
      if (newSource) _attempts = 0;
      await action();
    });
  }

  void _invalidateRecovery() {
    final hadPendingRecovery = _recoveryTimer != null || _recoveryQueued;
    ++_recoveryRevision;
    _watchdog?.cancel();
    _watchdog = null;
    _recoveryTimer?.cancel();
    _recoveryTimer = null;
    _recoveryQueued = false;
    _lastPosition = null;
    _lastProgress = null;
    _stableSince = null;
    if (hadPendingRecovery && !_disposed) notifyListeners();
  }

  bool get _recoveryEligible =>
      !_disposed &&
      recovery.enabled &&
      _foreground &&
      _wantsPlayback &&
      _source?.type == LumioSourceType.network &&
      (configuration.mode == LumioPlaybackMode.live || value.live) &&
      !value.transitioning &&
      !value.completed;

  bool _temporaryError(LumioPlayerError error) {
    if (error.code == 'ios_native_terminal_error') return false;
    if (error.code == 'ios_live_network_interruption') {
      // AVPlayer classifies the typed error chain and current item's live
      // evidence. Historical diagnostic entries must not override that result.
      return error.recoverable &&
          value.engine == LumioPlaybackEngine.native &&
          value.live;
    }
    if (error.code == 'hls_live_segment_unavailable') {
      // Only the native HLS loader can distinguish a missing media chunk from
      // a missing manifest/key. Never infer this exception from a generic 404.
      return error.recoverable &&
          value.engine == LumioPlaybackEngine.native &&
          value.initialized &&
          value.live;
    }
    final text = '${error.code} ${error.message} ${error.details}'
        .toLowerCase();
    // Media3 names, HTTP statuses, AVFoundation and NSURLError codes.
    if (RegExp(
          r'auth|(?:^|[^0-9])(401|403|404)(?:[^0-9]|$)|invalid|unsupported|codec|decoder|decoding|malformed|not.found|out.of.range|parsing|permission|denied',
        ).hasMatch(text) ||
        RegExp(
          r'-(1000|1002|1011|1012|1013|1100|11828|11829|11850)\b',
        ).hasMatch(text)) {
      return false;
    }
    return error.recoverable ||
        RegExp(
          r'network|\bio\b|io_|timeout|timed.out|behind_live_window|connection|temporar',
        ).hasMatch(text) ||
        RegExp(
          r'-(1001|1003|1004|1005|1006|1009|1018|1019|1020|11819)\b',
        ).hasMatch(text);
  }

  void _scheduleRecovery(LumioPlayerError error) {
    if (!_temporaryError(error)) {
      _invalidateRecovery();
      return;
    }
    if (!_recoveryEligible || _recoveryTimer != null || _recoveryQueued) {
      return;
    }
    _watchdog?.cancel();
    _watchdog = null;
    _stableSince = null;
    if (_attempts >= recovery.maxAttempts) {
      value = value.copyWith(error: error, buffering: false);
      return;
    }
    var delay = recovery.initialDelay;
    for (var i = 0; i < _attempts && delay < recovery.maxDelay; i++) {
      delay *= 2;
      if (delay > recovery.maxDelay) delay = recovery.maxDelay;
    }
    final revision = _recoveryRevision;
    final engine = value.engine;
    _recoveryTimer = Timer(delay, () {
      _recoveryTimer = null;
      if (revision != _recoveryRevision || !_recoveryEligible) {
        if (!_disposed) notifyListeners();
        return;
      }
      _recoveryQueued = true;
      unawaited(
        _serialize(() async {
          if (revision != _recoveryRevision || !_recoveryEligible) {
            _recoveryQueued = false;
            if (!_disposed) notifyListeners();
            return;
          }
          _recoveryQueued = false;
          ++_attempts;
          _log(
            LumioLogLevel.warning,
            'recovery_attempt',
            'Live network restart $_attempts/${recovery.maxAttempts}.',
            engine: engine,
          );
          _recoveryInProgress = true;
          try {
            await _start(
              engine,
              autoPlay: _wantsPlayback,
              recovering: true,
              recoverToLive:
                  error.code == 'hls_live_segment_unavailable' ||
                  error.code == 'ios_live_network_interruption',
            );
          } finally {
            _recoveryInProgress = false;
            if (!_disposed) notifyListeners();
          }
        }).catchError((Object _) {}),
      );
    });
    notifyListeners();
  }

  void _armWatchdog() {
    if (!_recoveryEligible ||
        !value.initialized ||
        value.error != null ||
        _watchdog != null ||
        _recoveryTimer != null ||
        _recoveryQueued) {
      return;
    }
    _lastPosition = value.position;
    _lastProgress = DateTime.now();
    _stableSince = null;
    final interval = Duration(
      microseconds: (recovery.stallTimeout.inMicroseconds ~/ 4).clamp(
        1,
        1000000,
      ),
    );
    _watchdog = Timer.periodic(interval, (_) {
      if (!_recoveryEligible || !value.initialized || value.error != null) {
        _watchdog?.cancel();
        _watchdog = null;
        _stableSince = null;
        return;
      }
      final elapsed = DateTime.now().difference(_lastProgress!);
      if (elapsed >= recovery.stallTimeout) {
        const error = LumioPlayerError(
          code: 'live_position_stall',
          message: 'Live playback position stopped advancing (heuristic).',
          recoverable: true,
        );
        value = value.copyWith(error: error);
        _scheduleRecovery(error);
      } else if (elapsed >= recovery.stallTimeout ~/ 2) {
        _stableSince = null;
      }
    });
  }

  void _observeProgress() {
    if (!_recoveryEligible || !value.initialized || value.error != null) {
      _stableSince = null;
      return;
    }
    _armWatchdog();
    final position = value.position;
    if (_lastPosition != null && position > _lastPosition!) {
      final now = DateTime.now();
      _stableSince ??= now;
      _lastProgress = now;
      if (now.difference(_stableSince!) >= recovery.stablePlaybackDuration) {
        _attempts = 0;
      }
    } else if (_lastPosition != null && position < _lastPosition!) {
      _stableSince = null;
    }
    _lastPosition = position;
  }

  final _logs = StreamController<LumioLogEntry>.broadcast();

  LumioSource? get source => _source;
  LumioPlaylist? get playlist => _playlist;
  int get playlistIndex => _playlistIndex;
  LumioPlaylistItem? get currentItem => _playlist?.items[_playlistIndex];
  String? get title => currentItem?.title ?? _title;
  bool get hasNext =>
      _playlist != null &&
      _playlist!.items.length > 1 &&
      (_playlistIndex < _playlist!.items.length - 1 || _playlist!.loop);
  bool get hasPrevious =>
      _playlist != null &&
      _playlist!.items.length > 1 &&
      (_playlistIndex > 0 || _playlist!.loop);
  int? get textureId => _textureId;
  int? get nativePlayerId => _id;
  LumioNativeViewType get nativeViewType => configuration.nativeViewType;
  WebViewController? get webViewController => _web?.controller;
  LumioPlaybackEngine get requestedEngine => _requestedEngine;
  bool get looping => _looping;
  Stream<LumioLogEntry> get logs => _logs.stream;

  LumioCapabilities get capabilities {
    final web = value.engine == LumioPlaybackEngine.webview;
    final android = defaultTargetPlatform == TargetPlatform.android;
    return LumioCapabilities(
      engine: value.engine,
      network: true,
      localFiles: !web,
      assets: !web,
      httpHeaders:
          !web && (android || defaultTargetPlatform == TargetPlatform.iOS),
      detailedBufferControl: !web && android,
      volumeControl: !(web && defaultTargetPlatform == TargetPlatform.iOS),
      nativePlaylist: !web,
      nativePlatformView:
          !web &&
          !kIsWeb &&
          (android || defaultTargetPlatform == TargetPlatform.iOS),
      supportsSurfaceCapture:
          !web &&
          !kIsWeb &&
          (android || defaultTargetPlatform == TargetPlatform.iOS) &&
          nativeViewType == LumioNativeViewType.texture,
      formats: Set.unmodifiable(
        web || !android
            ? {
                LumioMediaFormat.auto,
                LumioMediaFormat.hls,
                LumioMediaFormat.progressive,
              }
            : LumioMediaFormat.values.toSet(),
      ),
    );
  }

  Future<void> _serialize(Future<void> Function() action) {
    if (_disposed) {
      return Future.error(StateError('Lumio player has been disposed.'));
    }
    final result = _queue.then((_) {
      if (_disposed) throw StateError('Lumio player has been disposed.');
      return action();
    });
    _queue = result.then<void>((_) {}, onError: (Object _, StackTrace _) {});
    return result;
  }

  LumioSource _withHeaders(LumioSource source, Map<String, String> overrides) {
    if (source.type != LumioSourceType.network) return source;
    if (httpHeaders.isEmpty && overrides.isEmpty) return source;
    final merged = <String, String>{};
    for (final headers in [httpHeaders, source.headers, overrides]) {
      for (final entry in headers.entries) {
        merged.removeWhere(
          (key, _) => key.toLowerCase() == entry.key.toLowerCase(),
        );
        merged[entry.key] = entry.value;
      }
    }
    return LumioSource.network(
      Uri.parse(source.uri),
      headers: merged,
      format: source.format,
    );
  }

  Future<void> openUrl(
    String url, {
    Map<String, String> headers = const {},
    String? title,
    LumioMediaFormat format = LumioMediaFormat.auto,
  }) => open(
    LumioSource.network(Uri.parse(url), format: format),
    headers: headers,
    title: title,
  );

  Future<void> open(
    LumioSource source, {
    Map<String, String> headers = const {},
    String? title,
  }) => _changePlayback(() async {
    _playlist = null;
    _playlistIndex = 0;
    _title = title;
    _source = _withHeaders(source, headers);
    _fallbackUsed = false;
    await _start(
      _requestedEngine == LumioPlaybackEngine.webview
          ? LumioPlaybackEngine.webview
          : LumioPlaybackEngine.native,
      autoPlay: _wantsPlayback,
    );
  }, newSource: true);

  Future<void> openPlaylist(
    LumioPlaylist playlist, {
    int initialIndex = 0,
    Map<String, String> headers = const {},
  }) => _changePlayback(() async {
    if (initialIndex < 0 || initialIndex >= playlist.items.length) {
      throw RangeError.index(initialIndex, playlist.items);
    }
    _playlist = LumioPlaylist([
      for (final item in playlist.items)
        LumioPlaylistItem(
          source: _withHeaders(item.source, headers),
          title: item.title,
        ),
    ], loop: playlist.loop);
    _playlistIndex = initialIndex;
    _title = null;
    _source = _playlist!.items[initialIndex].source;
    _fallbackUsed = false;
    await _start(
      _requestedEngine == LumioPlaybackEngine.webview
          ? LumioPlaybackEngine.webview
          : LumioPlaybackEngine.native,
      autoPlay: _wantsPlayback,
    );
  }, newSource: true);

  Future<void> next() => _changePlayback(() async {
    if (!hasNext) return;
    await _selectPlaylistItem((_playlistIndex + 1) % _playlist!.items.length);
  });
  Future<void> previous() => _changePlayback(() async {
    if (!hasPrevious) return;
    await _selectPlaylistItem(
      (_playlistIndex - 1 + _playlist!.items.length) % _playlist!.items.length,
    );
  });
  Future<void> selectPlaylistItem(int index) => _changePlayback(() async {
    final playlist = _playlist;
    if (playlist == null) {
      throw StateError('Open a playlist before selecting an item.');
    }
    if (index < 0 || index >= playlist.items.length) {
      throw RangeError.index(index, playlist.items);
    }
    await _selectPlaylistItem(index);
  });

  Future<void> _selectPlaylistItem(int index) async {
    _invalidateRecovery();
    _attempts = 0;
    _playlistIndex = index;
    _source = _playlist!.items[index].source;
    _fallbackUsed = false;
    if (_web != null || _id == null) {
      await _start(value.engine, autoPlay: _wantsPlayback);
      return;
    }
    final selectionEpoch = ++_selectionEpoch;
    _nativeSelectionIndex = index;
    final ready = Completer<void>();
    final cancelled = Completer<void>();
    _cancelPending = cancelled;
    final watch = Stopwatch()..start();
    Future<T> guarded<T>(Future<T> action) => Future.any<T>([
      action,
      cancelled.future.then<T>(
        (_) => throw StateError('Playlist selection cancelled.'),
      ),
    ]).timeout(configuration.initializationTimeout - watch.elapsed);
    _ready = ready;
    final waiting = ready.future.timeout(configuration.initializationTimeout);
    unawaited(waiting.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    _beginStartup();
    _startup?.created();
    value = value.copyWith(
      clearFirstFrame: true,
      initialized: false,
      playing: false,
      completed: false,
      buffering: true,
      transitioning: true,
      position: Duration.zero,
      duration: Duration.zero,
      buffered: const [],
      bufferedPosition: Duration.zero,
      playlistIndex: index,
      clearError: true,
    );
    try {
      await guarded(
        _bridge.invoke('selectPlaylistItem', _id!, {
          'index': index,
          'selectionEpoch': selectionEpoch,
        }),
      );
      final requestedPlay = _effectivePlayback;
      if (requestedPlay) await guarded(_bridge.invoke('play', _id!));
      await guarded(waiting);
      if (_disposed) throw StateError('Player disposed during selection.');
      if (!_effectivePlayback && (requestedPlay || value.playing)) {
        await guarded(_bridge.invoke('pause', _id!));
      }
      value = value.copyWith(transitioning: false, clearError: true);
      _armWatchdog();
    } catch (error) {
      if (_disposed) rethrow;
      final failure = _asError(error, value.engine);
      value = value.copyWith(
        transitioning: false,
        buffering: false,
        error: failure,
      );
      _log(
        LumioLogLevel.error,
        failure.code,
        failure.message,
        engine: value.engine,
      );
      if (_canFallback(failure)) {
        _fallbackUsed = true;
        await _start(LumioPlaybackEngine.webview, autoPlay: _wantsPlayback);
      } else {
        _scheduleRecovery(failure);
        throw failure;
      }
    } finally {
      if (identical(_ready, ready)) _ready = null;
      if (identical(_cancelPending, cancelled)) _cancelPending = null;
      if (_selectionEpoch == selectionEpoch) _nativeSelectionIndex = null;
    }
  }

  Future<void> setEngine(LumioPlaybackEngine engine) => _changePlayback(
    () async {
      _requestedEngine = engine;
      _fallbackUsed = false;
      if (_source == null) return;
      final target = engine == LumioPlaybackEngine.automatic
          ? LumioPlaybackEngine.native
          : engine;
      if (target == value.engine && value.initialized && value.error == null) {
        return;
      }
      final previous = value;
      await _start(
        target,
        autoPlay: _wantsPlayback,
        position: previous.live ? Duration.zero : previous.position,
      );
    },
  );

  Future<void> retry() => _changePlayback(() async {
    if (_source == null) throw StateError('Open a source before retrying.');
    _attempts = 0;
    final previous = value;
    _fallbackUsed = false;
    await _start(
      _requestedEngine == LumioPlaybackEngine.webview
          ? LumioPlaybackEngine.webview
          : LumioPlaybackEngine.native,
      autoPlay: _wantsPlayback,
      position: previous.live ? Duration.zero : previous.position,
    );
  });

  Future<void> _start(
    LumioPlaybackEngine engine, {
    required bool autoPlay,
    Duration position = Duration.zero,
    bool recovering = false,
    bool recoverToLive = false,
  }) async {
    final startupClock = Stopwatch()..start();
    _watchdog?.cancel();
    _watchdog = null;
    _lastPosition = null;
    _lastProgress = null;
    _stableSince = null;
    value = value.copyWith(buffered: const [], bufferedPosition: Duration.zero);
    await _release();
    if (_disposed) throw StateError('Player disposed during initialization.');
    _selectionEpoch = 0;
    _nativeSelectionIndex = null;
    _beginStartup(recovering: recovering, clock: startupClock);
    final generation = ++_generation;
    final source = _source!;
    value = LumioPlayerState(
      engine: engine,
      transitioning: true,
      buffering: true,
      live: configuration.mode == LumioPlaybackMode.live,
      volume: _volume,
      speed: _speed,
      playlistIndex: _playlistIndex,
      playlistLength: _playlist?.items.length ?? 1,
    );
    final ready = Completer<void>();
    final cancelled = Completer<void>();
    _cancelPending = cancelled;
    final watch = Stopwatch()..start();
    Future<T> guarded<T>(Future<T> action) => Future.any<T>([
      action,
      cancelled.future.then<T>(
        (_) => throw StateError('Initialization cancelled.'),
      ),
    ]).timeout(configuration.initializationTimeout - watch.elapsed);
    _ready = ready;
    // Install a handler before a synchronous platform error can complete ready.
    final waiting = ready.future.timeout(configuration.initializationTimeout);
    unawaited(waiting.then<void>((_) {}, onError: (Object _, StackTrace _) {}));
    final config = {
      ...configuration.toMap(),
      // Recovery starts paused: late native readiness cannot revive a paused
      // request. Play is submitted only after readiness and a fresh intent check.
      'autoPlay': autoPlay && _effectivePlayback && !recovering,
      'volume': _volume,
      'speed': _speed,
      'looping': _looping,
      if (engine == LumioPlaybackEngine.webview) ...{
        'fit': _videoFit.name,
        'mode': configuration.mode.name,
      },
      if (_playlist != null) 'loopPlaylist': _playlist!.loop,
    };
    _log(
      LumioLogLevel.info,
      'opening',
      'Opening ${source.type.name}/${source.format.name}.',
      engine: engine,
    );
    try {
      if (engine == LumioPlaybackEngine.webview) {
        if (!source.supportsWebView) {
          throw const LumioPlayerError(
            code: 'unsupported_web_source',
            message:
                'WebView requires HTTP(S), no custom headers, and a progressive/HLS source.',
          );
        }
        if (!capabilities.volumeControl && _volume != 0 && _volume != 1) {
          _log(
            LumioLogLevel.warning,
            'unsupported_volume_gain',
            'iOS WebView supports mute/unmute only; fractional volume is retained for native playback.',
            engine: engine,
          );
        }
        final web = LumioWebEngine(
          onEvent: (event) => _onEvent(event, generation),
        );
        _web = web;
        _startup?.created();
        value = value;
        await guarded(web.open(source.toMap(), config));
      } else {
        // Subscribe before create/open to capture early native state events.
        _subscription = LumioNativeBridge.events.listen(
          (event) {
            if (event['id'] == _id) _onEvent(event, generation);
          },
          onError: (Object error) => _onEvent({
            'type': 'error',
            'code': 'event_channel',
            'message': 'Native event channel failed.',
            'details': error.toString(),
          }, generation),
        );
        var createAbandoned = false;
        ++_pendingNativeCreations;
        final creation = _bridge.create(viewType: nativeViewType);
        unawaited(
          creation.then<void>(
            (created) async {
              --_pendingNativeCreations;
              if (createAbandoned) {
                ++_pendingLateReleases;
                await _releaseStep(
                  'late_native',
                  LumioPlaybackEngine.native,
                  () =>
                      _bridge.invoke('dispose', (created['id'] as num).toInt()),
                );
                --_pendingLateReleases;
              }
              _maybeLogDisposed();
            },
            onError: (Object _, StackTrace _) {
              --_pendingNativeCreations;
              _maybeLogDisposed();
            },
          ),
        );
        late final Map<String, dynamic> created;
        try {
          created = await guarded(creation);
        } catch (_) {
          createAbandoned = true;
          rethrow;
        }
        if (_disposed || generation != _generation) {
          await _releaseStep(
            'abandoned_native',
            LumioPlaybackEngine.native,
            () => _bridge.invoke('dispose', (created['id'] as num).toInt()),
          );
          throw StateError('Initialization cancelled.');
        }
        _startup?.created();
        _id = (created['id'] as num).toInt();
        _textureId = (created['textureId'] as num?)?.toInt();
        config['autoPlay'] = autoPlay && _effectivePlayback && !recovering;
        value = value;
        await guarded(
          _bridge.invoke(_playlist == null ? 'open' : 'openPlaylist', _id!, {
            if (_playlist == null)
              'source': source.toMap()
            else
              'sources': [
                for (final item in _playlist!.items) item.source.toMap(),
              ],
            if (_playlist != null) 'index': _playlistIndex,
            'config': config,
          }),
        );
      }
      await guarded(waiting);
      if (_disposed || generation != _generation) {
        throw StateError('Initialization cancelled.');
      }
      if (value.error != null) throw value.error!;
      if (position > Duration.zero && !value.live) {
        await _command('seek', {'positionMs': position.inMilliseconds});
      }
      if (recovering && recoverToLive && value.live && _effectivePlayback) {
        await _command('seekToLive');
      }
      final resumeRecovery = recovering && autoPlay && _effectivePlayback;
      if (resumeRecovery) await _command('play');
      if (!_effectivePlayback &&
          (config['autoPlay'] == true || resumeRecovery || value.playing)) {
        await _command('pause');
      }
      value = value.copyWith(transitioning: false, clearError: true);
      _armWatchdog();
      _log(LumioLogLevel.info, 'ready', 'Media initialized.', engine: engine);
    } catch (error) {
      if (_disposed) rethrow;
      final failure = _asError(error, engine);
      _recordFailure(
        failure,
        details: error is PlatformException ? error.details : null,
      );
      if (!recovering && _canFallback(failure)) {
        _fallbackUsed = true;
        _log(
          LumioLogLevel.warning,
          'fallback',
          '${failure.code}: trying WebView.',
          engine: engine,
        );
        await _start(
          LumioPlaybackEngine.webview,
          autoPlay: autoPlay,
          position: position,
        );
      } else {
        value = value.copyWith(
          initialized: false,
          playing: false,
          transitioning: false,
          buffering: false,
          error: failure,
        );
        _log(
          LumioLogLevel.error,
          failure.code,
          failure.message,
          engine: engine,
        );
        await _release();
        _scheduleRecovery(failure);
        throw failure;
      }
    } finally {
      if (identical(_ready, ready)) _ready = null;
      if (identical(_cancelPending, cancelled)) _cancelPending = null;
    }
  }

  bool _canFallback(LumioPlayerError error) {
    // Opt-in live recovery retries transient failures on the selected engine.
    if (recovery.enabled &&
        _wantsPlayback &&
        _foreground &&
        _source?.type == LumioSourceType.network &&
        (configuration.mode == LumioPlaybackMode.live || value.live) &&
        _temporaryError(error)) {
      return false;
    }
    if (_requestedEngine != LumioPlaybackEngine.automatic ||
        !configuration.allowAutomaticFallback ||
        _fallbackUsed ||
        value.engine != LumioPlaybackEngine.native ||
        !(_source?.supportsWebView ?? false)) {
      return false;
    }
    final code = error.code.toLowerCase();
    if (['network', 'http', 'auth', 'io_'].any(code.contains)) return false;
    return [
      'codec',
      'decoder',
      'decoding',
      'unsupported',
      'format',
      'render',
      'timeout',
    ].any(code.contains);
  }

  void _onEvent(Map<String, dynamic> event, int generation) {
    if (_disposed || generation != _generation) return;
    if (event['type'] == 'error') {
      final failedIndex = (event['playlistIndex'] as num?)?.toInt();
      if (_playlist != null &&
          failedIndex != null &&
          failedIndex != _playlistIndex) {
        return;
      }
      final error = LumioPlayerError(
        code: event['code']?.toString() ?? 'native_error',
        message: _redact(event['message']?.toString() ?? 'Playback failed.'),
        details: _redact(event['details']?.toString() ?? ''),
        recoverable: event['recoverable'] == true,
        engine: value.engine,
      );
      _recordFailure(error, details: event['details']);
      if (_ready != null && !_ready!.isCompleted) {
        _ready!.completeError(error);
      } else if (!value.transitioning && _canFallback(error)) {
        _fallbackUsed = true;
        final previous = value;
        final revision = _recoveryRevision;
        unawaited(
          _serialize(() async {
            if (generation != _generation || revision != _recoveryRevision) {
              return;
            }
            await _start(
              LumioPlaybackEngine.webview,
              autoPlay: _wantsPlayback,
              position: previous.live ? Duration.zero : previous.position,
            );
          }).catchError((Object _) {}),
        );
      } else {
        value = value.copyWith(error: error, buffering: false);
        _scheduleRecovery(error);
      }
      _log(
        LumioLogLevel.error,
        error.code,
        error.message,
        engine: value.engine,
      );
    } else if (event['type'] == 'state') {
      if (value.engine == LumioPlaybackEngine.native) {
        final epoch = event['selectionEpoch'];
        if (epoch is num && epoch != _selectionEpoch) return;
        // Legacy snapshots cannot distinguish same-index reselections. At
        // least prevent an old index from undoing an explicit pending choice.
        if (epoch is! num &&
            _nativeSelectionIndex != null &&
            event['playlistIndex'] is num &&
            event['playlistIndex'] != _nativeSelectionIndex) {
          return;
        }
      }
      final index = (event['playlistIndex'] as num?)?.toInt();
      final playlist = _playlist;
      final changed =
          playlist != null &&
          index != null &&
          index >= 0 &&
          index < playlist.items.length &&
          index != _playlistIndex;
      if (changed) {
        _beginStartup();
        _invalidateRecovery();
        _attempts = 0;
        _playlistIndex = index;
        _source = playlist.items[index].source;
        _fallbackUsed = false;
      }
      value =
          (changed
                  ? value.copyWith(
                      clearFirstFrame: true,
                      buffered: const [],
                      bufferedPosition: Duration.zero,
                    )
                  : value)
              .apply(event)
              .copyWith(
                playlistIndex: _playlistIndex,
                playlistLength: playlist?.items.length ?? value.playlistLength,
                clearError: changed,
              );
      if (value.engine == LumioPlaybackEngine.webview &&
          value.completed &&
          playlist != null &&
          !_looping &&
          !_webAdvanceQueued &&
          hasNext) {
        _webAdvanceQueued = true;
        unawaited(
          _serialize(() async {
                if (_generation != generation ||
                    !identical(_playlist, playlist) ||
                    !value.completed) {
                  return;
                }
                await _selectPlaylistItem(
                  (_playlistIndex + 1) % playlist.items.length,
                );
              })
              .catchError((Object error) {
                if (!_disposed) {
                  _log(
                    LumioLogLevel.error,
                    'playlist_advance_failed',
                    'The next WebView playlist item could not be opened.',
                    engine: value.engine,
                  );
                }
              })
              .whenComplete(() => _webAdvanceQueued = false),
        );
      }
      if (!_effectivePlayback &&
          value.transitioning &&
          value.initialized &&
          value.playing) {
        unawaited(
          _command('pause').catchError((Object error) {
            if (!_disposed && generation == _generation) {
              value = value.copyWith(error: _asError(error, value.engine));
            }
          }),
        );
      }
      _observeProgress();
      if (value.initialized && _ready != null && !_ready!.isCompleted) {
        _ready!.complete();
      }
    }
  }

  /// [isCurrent] is checked when the command reaches the front of the queue,
  /// before touching the engine. A stale command fails rather than succeeding
  /// silently, so callers cannot mistake cancellation for completed playback.
  Future<void> play({bool Function()? isCurrent}) {
    final revision = isCurrent == null ? ++_intentRevision : _intentRevision;
    if (isCurrent == null) {
      _wantsPlayback = true;
      if (!_disposed) value = value;
    }
    return _serialize(() async {
      _checkCurrent(isCurrent);
      if (isCurrent != null) {
        _wantsPlayback = true;
        ++_intentRevision;
      }
      value = value;
      if (!_foreground && !configuration.allowBackgroundPlayback) return;
      await _command('play');
      // A later pause already owns intent; command completion must not undo it.
      if (isCurrent == null && revision == _intentRevision) {
        _wantsPlayback = true;
      }
      _armWatchdog();
    });
  }

  /// Optional execution-time guard, with the same semantics as [play].
  Future<void> pause({bool Function()? isCurrent}) {
    if (isCurrent == null) {
      _wantsPlayback = false;
      ++_intentRevision;
      _invalidateRecovery();
      if (!_disposed) value = value;
    }
    return _serialize(() async {
      _checkCurrent(isCurrent);
      if (isCurrent != null) {
        _wantsPlayback = false;
        ++_intentRevision;
        _invalidateRecovery();
      }
      value = value;
      if (value.initialized) await _command('pause');
    });
  }

  /// Query the active backend, not the last periodic state event.
  /// Returns null before initialization. Stale queries and disposal throw
  /// StateError; a result never updates state for a different source/engine.
  Future<Duration?> getPosition() async {
    if (_disposed) throw StateError('Lumio player has been disposed.');
    if (!value.initialized) return null;
    final generation = _generation;
    final source = _source;
    final index = _playlistIndex;
    final revision = _recoveryRevision;
    final fallback = _fallbackUsed;
    final engine = value.engine;
    final id = _id;
    final web = _web;
    void check() {
      if (_disposed) throw StateError('Lumio player has been disposed.');
      if (generation != _generation ||
          !identical(source, _source) ||
          index != _playlistIndex ||
          revision != _recoveryRevision ||
          fallback != _fallbackUsed ||
          engine != value.engine ||
          id != _id ||
          !identical(web, _web)) {
        throw StateError('Position query is no longer current.');
      }
    }

    Duration? position;
    await _serialize(() async {
      check();
      if (!value.initialized) return;
      final Object? result;
      try {
        result =
            await (web != null
                    ? web.getPosition()
                    : _bridge.invoke('getPosition', id!))
                .timeout(configuration.commandTimeout);
      } catch (_) {
        check();
        rethrow;
      }
      check();
      if (result is! num || !result.isFinite || result < 0) {
        throw StateError('Backend returned an invalid position.');
      }
      position = Duration(milliseconds: result.toInt());
      value = value.copyWith(position: position);
    });
    check();
    return position;
  }

  /// Optional execution-time guard, with the same semantics as [play].
  Future<void> seekTo(Duration position, {bool Function()? isCurrent}) =>
      _serialize(() {
        _checkCurrent(isCurrent);
        if (position.isNegative) {
          throw ArgumentError('Seek position cannot be negative.');
        }
        return _command('seek', {'positionMs': position.inMilliseconds});
      });

  /// Seek used by scrubbing previews. Android waits for the renderer's first
  /// frame callback, bounded by a native deadline; this is not a guarantee of
  /// exact timestamp or Flutter texture composition. Other engines use seekTo.
  Future<void> seekToPreview(Duration position, {bool Function()? isCurrent}) {
    if (value.engine != LumioPlaybackEngine.native ||
        defaultTargetPlatform != TargetPlatform.android) {
      return seekTo(position, isCurrent: isCurrent);
    }
    return _serialize(() {
      _checkCurrent(isCurrent);
      if (position.isNegative) {
        throw ArgumentError('Seek position cannot be negative.');
      }
      return _command('seek', {
        'positionMs': position.inMilliseconds,
        'waitForFrame': true,
      });
    });
  }

  void _checkCurrent(bool Function()? isCurrent) {
    if (isCurrent != null && !isCurrent()) {
      throw StateError('Player command is no longer current.');
    }
  }

  /// Seek to the live edge/default live position, if the media has a live window.
  Future<void> seekToLive() => _serialize(() {
    if (!value.live) {
      throw const LumioPlayerError(
        code: 'unsupported_live_seek',
        message: 'The current source is not a live stream.',
      );
    }
    return _command('seekToLive');
  });

  Future<void> setVolume(double volume) => _serialize(() async {
    if (!volume.isFinite || volume < 0 || volume > 1) {
      throw ArgumentError('Volume must be between 0 and 1.');
    }
    if (!capabilities.volumeControl && volume != 0 && volume != 1) {
      throw const LumioPlayerError(
        code: 'unsupported_volume_gain',
        message: 'iOS WebView supports volume 0 (mute) or 1 (unmute) only.',
      );
    }
    await _command('volume', {'volume': volume});
    _volume = volume;
    value = value.copyWith(volume: volume);
  });
  Future<void> setSpeed(double speed) {
    if (!speed.isFinite || speed <= 0) {
      return Future.error(ArgumentError('Speed must be positive and finite.'));
    }
    ++_speedRevision;
    return _serialize(() => _applySpeed(speed));
  }

  Future<void> _applySpeed(double speed) async {
    await _command('speed', {'speed': speed});
    _speed = speed;
    value = value.copyWith(speed: speed);
  }

  /// Atomically releases a temporary rate without overwriting a newer command.
  Future<void> restoreSpeedIfUnchanged({
    required int revision,
    required double temporarySpeed,
    required double originalSpeed,
  }) => _serialize(() async {
    if (_speedRevision != revision || value.speed != temporarySpeed) return;
    ++_speedRevision;
    await _applySpeed(originalSpeed);
  });
  Future<void> setLooping(bool looping) => _serialize(() async {
    await _command('looping', {'looping': looping});
    _looping = looping;
  });

  Future<void> _command(
    String method, [
    Map<String, Object?> args = const {},
  ]) async {
    if (_disposed || !value.initialized) {
      throw StateError('Player must be initialized before $method.');
    }
    try {
      if (_web != null) {
        await _web!.command(method, args);
      } else if (_id != null) {
        await _bridge
            .invoke(method, _id!, args)
            .timeout(configuration.commandTimeout);
      } else {
        throw StateError('No active engine.');
      }
    } catch (error) {
      final failure = error is TimeoutException
          ? LumioPlayerError(
              code: 'command_timeout',
              message: 'The $method command timed out.',
              engine: value.engine,
            )
          : _asError(error, value.engine);
      _recordFailure(
        failure,
        details: error is PlatformException ? error.details : null,
      );
      _log(
        LumioLogLevel.error,
        failure.code,
        failure.message,
        engine: value.engine,
      );
      throw failure;
    }
    if (_disposed) throw StateError('Player disposed during $method.');
  }

  Future<Map<String, dynamic>> diagnostics() async {
    if (_disposed) throw StateError('Player disposed.');
    final native = _web != null
        ? _web!.diagnostics
        : _id == null
        ? <String, Object?>{}
        : (await _bridge
                  .invoke('diagnostics', _id!)
                  .timeout(configuration.commandTimeout))
              as Map;
    // Native access logs may contain signed URLs: recursively redact strings.
    Object? sanitize(Object? object) {
      if (object is String) return _redact(object);
      if (object is Map) {
        return object.map(
          (key, val) => MapEntry(_redact(key.toString()), sanitize(val)),
        );
      }
      if (object is Iterable) return object.map(sanitize).toList();
      return object;
    }

    return {
      'engine': value.engine.name,
      'requestedEngine': _requestedEngine.name,
      'fallbackUsed': _fallbackUsed,
      'initialized': value.initialized,
      'phase': value.phase.name,
      'hasRenderedFirstFrame': value.hasRenderedFirstFrame,
      'firstFrameSupported': value.firstFrameSupported,
      'firstFrameEvidence': value.firstFrameEvidence?.name,
      'startup': startupDiagnostics,
      'playback': {
        'mode': configuration.mode.name,
        'fit': _videoFit.name,
        'sourceType': _source?.type.name,
        'formatHint': _source?.format.name,
        'playing': value.playing,
        'buffering': value.buffering,
        'live': value.live,
        'positionMs': value.position.inMilliseconds,
        'durationMs': value.duration.inMilliseconds,
        'bufferAheadMs': (value.bufferedPosition - value.position)
            .inMilliseconds
            .clamp(0, 1 << 53),
        'width': value.size.width,
        'height': value.size.height,
        'speed': value.speed,
        'volume': value.volume,
        'playlistIndex': _playlistIndex,
        'playlistLength': value.playlistLength,
        'lastErrorCode': value.error == null
            ? null
            : _redact(value.error!.code),
      },
      'native': sanitize(native),
    };
  }

  LumioPlayerError _asError(Object error, LumioPlaybackEngine engine) {
    if (error is LumioPlayerError) return error;
    if (error is PlatformException) {
      return LumioPlayerError(
        code: error.code,
        message: _redact(error.message ?? 'Native command failed.'),
        details: _redact(error.details?.toString() ?? ''),
        recoverable:
            error.details is Map &&
            (error.details as Map)['recoverable'] == true,
        engine: engine,
      );
    }
    return LumioPlayerError(
      code: error is TimeoutException
          ? 'initialization_timeout'
          : 'initialization_failed',
      message: _redact(error.toString()),
      engine: engine,
    );
  }

  String _redact(String input) {
    var output = input;
    final sources = [
      ?_source,
      if (_playlist != null) ..._playlist!.items.map((item) => item.source),
    ];
    for (final source in sources) {
      output = output.replaceAll(source.uri, '[source]');
      for (final secret in source.headers.values) {
        if (secret.isNotEmpty) output = output.replaceAll(secret, '[redacted]');
      }
    }
    for (final secret in httpHeaders.values) {
      if (secret.isNotEmpty) output = output.replaceAll(secret, '[redacted]');
    }
    return output.replaceAll(
      RegExp(r'(?:https?|rtsp)://[^\s\]\)\"\x27]+'),
      '[url]',
    );
  }

  void _log(
    LumioLogLevel level,
    String code,
    String message, {
    LumioPlaybackEngine? engine,
    bool lifecycle = false,
  }) {
    if (_disposed && !lifecycle) return;
    final entry = LumioLogEntry(
      level,
      _redact(code),
      _redact(message),
      engine: engine,
      playerId: playerId,
    );
    if (!_logs.isClosed) _logs.add(entry);
    try {
      logger?.call(entry);
    } catch (_) {
      /* Logging must not interrupt playback. */
    }
  }

  void _notifySurface() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _releaseStep(
    String resource,
    LumioPlaybackEngine engine,
    Future<Object?> Function() release,
  ) async {
    final watch = Stopwatch()..start();
    _log(
      LumioLogLevel.info,
      'resources_release_started',
      'Releasing $resource resources.',
      engine: engine,
      lifecycle: true,
    );
    try {
      await release().timeout(const Duration(seconds: 5));
      _log(
        LumioLogLevel.info,
        'resources_released',
        '$resource cleanup acknowledged (${watch.elapsedMilliseconds} ms).',
        engine: engine,
        lifecycle: true,
      );
    } catch (error) {
      _cleanupFailed = true;
      final reason = error is TimeoutException ? 'timeout' : 'release error';
      _log(
        LumioLogLevel.warning,
        'dispose_failed',
        '$resource cleanup not confirmed: $reason. Continuing other cleanup steps.',
        engine: engine,
        lifecycle: true,
      );
    }
  }

  Future<void> _release() async {
    if (!_disposed) await _failureDiagnostics;
    ++_generation;
    final subscription = _subscription;
    final web = _web;
    final id = _id;
    final engine = value.engine;
    _subscription = null;
    _web = null;
    _id = null;
    _textureId = null;
    // Every resource gets its own attempt, even when an earlier release fails.
    if (subscription != null) {
      await _releaseStep('event_subscription', engine, subscription.cancel);
    }
    if (web != null) {
      await _releaseStep(
        'webview_media',
        LumioPlaybackEngine.webview,
        web.dispose,
      );
    }
    if (id != null) {
      await _releaseStep(
        'native_player',
        LumioPlaybackEngine.native,
        () => _bridge.invoke('dispose', id),
      );
    }
    _notifySurface();
  }

  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    final completion = Completer<void>();
    _disposal = completion.future;
    _disposed = true;
    _startup?.stop();
    WidgetsBinding.instance.removeObserver(this);
    _invalidateRecovery();
    _disposalWatch.start();
    _log(
      LumioLogLevel.info,
      'dispose_started',
      'Disposing player; rejecting new commands and invalidating engine events.',
      engine: value.engine,
      lifecycle: true,
    );
    _cancelPending?.complete();
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(StateError('Player disposed.'));
    }
    super.dispose();
    unawaited(
      _close().then(completion.complete, onError: completion.completeError),
    );
    return _disposal!;
  }

  void _maybeLogDisposed() {
    if (!_closeFinished) return;
    if (_cleanupFailed) {
      if (!_incompleteLogged) {
        _incompleteLogged = true;
        _log(
          LumioLogLevel.warning,
          'dispose_incomplete',
          'Player detached, but resource cleanup could not be fully confirmed.',
          engine: value.engine,
          lifecycle: true,
        );
      }
      return;
    }
    if (_pendingNativeCreations != 0 ||
        _pendingLateReleases != 0 ||
        _disposedLogged) {
      return;
    }
    _disposedLogged = true;
    _disposalWatch.stop();
    _log(
      LumioLogLevel.info,
      'disposed',
      'Player disposal confirmed (${_disposalWatch.elapsedMilliseconds} ms): media resources released and engine callbacks invalidated.',
      engine: value.engine,
      lifecycle: true,
    );
  }

  Future<void> _close() async {
    await _release();
    try {
      await _queue.timeout(const Duration(seconds: 5));
    } catch (_) {
      _cleanupFailed = true;
      _log(
        LumioLogLevel.warning,
        'dispose_failed',
        'Pending command completion not confirmed within the disposal deadline.',
        engine: value.engine,
        lifecycle: true,
      );
    }
    _closeFinished = true;
    if (_pendingNativeCreations != 0 || _pendingLateReleases != 0) {
      _log(
        LumioLogLevel.warning,
        'dispose_pending',
        'Player detached; waiting for late native creation cleanup. Confirmation will follow through the logger.',
        engine: value.engine,
        lifecycle: true,
      );
    }
    _maybeLogDisposed();
    _source = null;
    _playlist = null;
    _title = null;
    await _logs.close();
  }
}
