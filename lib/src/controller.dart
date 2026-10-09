import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/painting.dart' show BoxFit;
import 'package:flutter/services.dart';
import 'package:webview_flutter/webview_flutter.dart';

import 'models.dart';
import 'native_bridge.dart';
import 'web_engine.dart';

/// A player instance. Mount LumioPlayerView before awaiting WebView initialization.
/// Commands are serialized; dispose invalidates all outstanding engine events.
class LumioPlayerController extends ValueNotifier<LumioPlayerState> {
  LumioPlayerController({
    this.configuration = const LumioPlayerConfiguration(),
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
  }
  final LumioPlayerConfiguration configuration;
  final LumioLogger? logger;

  /// Default headers for network sources. Per-source/open headers take precedence.
  final Map<String, String> httpHeaders;
  final _bridge = LumioNativeBridge();
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
      httpHeaders: !web && android,
      detailedBufferControl: !web && android,
      volumeControl: !(web && defaultTargetPlatform == TargetPlatform.iOS),
      nativePlaylist: !web,
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
  }) => _serialize(() async {
    _playlist = null;
    _playlistIndex = 0;
    _title = title;
    _source = _withHeaders(source, headers);
    _wantsPlayback = configuration.autoPlay;
    _fallbackUsed = false;
    await _start(
      _requestedEngine == LumioPlaybackEngine.webview
          ? LumioPlaybackEngine.webview
          : LumioPlaybackEngine.native,
      autoPlay: configuration.autoPlay,
    );
  });

  Future<void> openPlaylist(
    LumioPlaylist playlist, {
    int initialIndex = 0,
    Map<String, String> headers = const {},
  }) => _serialize(() async {
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
    _wantsPlayback = configuration.autoPlay;
    _fallbackUsed = false;
    await _start(
      _requestedEngine == LumioPlaybackEngine.webview
          ? LumioPlaybackEngine.webview
          : LumioPlaybackEngine.native,
      autoPlay: _wantsPlayback,
    );
  });

  Future<void> next() => _serialize(() async {
    if (!hasNext) return;
    await _selectPlaylistItem((_playlistIndex + 1) % _playlist!.items.length);
  });
  Future<void> previous() => _serialize(() async {
    if (!hasPrevious) return;
    await _selectPlaylistItem(
      (_playlistIndex - 1 + _playlist!.items.length) % _playlist!.items.length,
    );
  });
  Future<void> selectPlaylistItem(int index) => _serialize(() async {
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
    _playlistIndex = index;
    _source = _playlist!.items[index].source;
    _fallbackUsed = false;
    if (_web != null || _id == null) {
      await _start(value.engine, autoPlay: _wantsPlayback);
      return;
    }
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
    value = value.copyWith(
      initialized: false,
      playing: false,
      completed: false,
      buffering: true,
      transitioning: true,
      position: Duration.zero,
      duration: Duration.zero,
      playlistIndex: index,
      clearError: true,
    );
    try {
      await guarded(
        _bridge.invoke('selectPlaylistItem', _id!, {'index': index}),
      );
      if (_wantsPlayback) await guarded(_bridge.invoke('play', _id!));
      await guarded(waiting);
      if (_disposed) throw StateError('Player disposed during selection.');
      value = value.copyWith(transitioning: false, clearError: true);
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
        throw failure;
      }
    } finally {
      if (identical(_ready, ready)) _ready = null;
      if (identical(_cancelPending, cancelled)) _cancelPending = null;
    }
  }

  Future<void> setEngine(LumioPlaybackEngine engine) => _serialize(() async {
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
  });

  Future<void> retry() => _serialize(() async {
    if (_source == null) throw StateError('Open a source before retrying.');
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
  }) async {
    await _release();
    if (_disposed) throw StateError('Player disposed during initialization.');
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
      'autoPlay': autoPlay,
      'volume': _volume,
      'speed': _speed,
      'looping': _looping,
      if (engine == LumioPlaybackEngine.webview) 'fit': _videoFit.name,
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
        _notifySurface();
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
        final creation = _bridge.create();
        unawaited(
          creation
              .then<void>((created) async {
                if (createAbandoned) {
                  await _bridge.invoke(
                    'dispose',
                    (created['id'] as num).toInt(),
                  );
                }
              })
              .catchError((Object _) {}),
        );
        late final Map<String, dynamic> created;
        try {
          created = await guarded(creation);
        } catch (_) {
          createAbandoned = true;
          rethrow;
        }
        if (_disposed || generation != _generation) {
          await _bridge.invoke('dispose', (created['id'] as num).toInt());
          throw StateError('Initialization cancelled.');
        }
        _id = (created['id'] as num).toInt();
        _textureId = (created['textureId'] as num).toInt();
        _notifySurface();
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
      if (position > Duration.zero && !value.live) {
        await _command('seek', {'positionMs': position.inMilliseconds});
      }
      value = value.copyWith(transitioning: false, clearError: true);
      _log(LumioLogLevel.info, 'ready', 'Media initialized.', engine: engine);
    } catch (error) {
      if (_disposed) rethrow;
      final failure = _asError(error, engine);
      if (_canFallback(failure)) {
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
        throw failure;
      }
    } finally {
      if (identical(_ready, ready)) _ready = null;
      if (identical(_cancelPending, cancelled)) _cancelPending = null;
    }
  }

  bool _canFallback(LumioPlayerError error) {
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
      if (_ready != null && !_ready!.isCompleted) {
        _ready!.completeError(error);
      } else if (!value.transitioning && _canFallback(error)) {
        _fallbackUsed = true;
        final previous = value;
        unawaited(
          _serialize(
            () => _start(
              LumioPlaybackEngine.webview,
              autoPlay: _wantsPlayback,
              position: previous.live ? Duration.zero : previous.position,
            ),
          ).catchError((Object _) {}),
        );
      } else {
        value = value.copyWith(error: error, buffering: false);
      }
      _log(
        LumioLogLevel.error,
        error.code,
        error.message,
        engine: value.engine,
      );
    } else if (event['type'] == 'state') {
      final index = (event['playlistIndex'] as num?)?.toInt();
      final playlist = _playlist;
      final changed =
          playlist != null &&
          index != null &&
          index >= 0 &&
          index < playlist.items.length &&
          index != _playlistIndex;
      if (changed) {
        _playlistIndex = index;
        _source = playlist.items[index].source;
        _fallbackUsed = false;
      }
      value = value
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
      if (value.initialized && _ready != null && !_ready!.isCompleted) {
        _ready!.complete();
      }
    }
  }

  Future<void> play() => _serialize(() async {
    await _command('play');
    _wantsPlayback = true;
  });
  Future<void> pause() => _serialize(() async {
    await _command('pause');
    _wantsPlayback = false;
  });
  Future<void> seekTo(Duration position) => _serialize(() {
    if (position.isNegative) {
      throw ArgumentError('Seek position cannot be negative.');
    }
    return _command('seek', {'positionMs': position.inMilliseconds});
  });

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
            .timeout(configuration.initializationTimeout);
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
      _log(
        LumioLogLevel.error,
        failure.code,
        failure.message,
        engine: value.engine,
      );
      throw failure;
    }
  }

  Future<Map<String, dynamic>> diagnostics() async {
    if (_disposed) throw StateError('Player disposed.');
    final native = _web != null
        ? _web!.diagnostics
        : _id == null
        ? <String, Object?>{}
        : (await _bridge
                  .invoke('diagnostics', _id!)
                  .timeout(configuration.initializationTimeout))
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
  }) {
    if (_disposed) return;
    final entry = LumioLogEntry(level, code, _redact(message), engine: engine);
    _logs.add(entry);
    try {
      logger?.call(entry);
    } catch (_) {
      /* Logging must not interrupt playback. */
    }
  }

  void _notifySurface() {
    if (!_disposed) notifyListeners();
  }

  Future<void> _release() async {
    ++_generation;
    final subscription = _subscription;
    final web = _web;
    final id = _id;
    _subscription = null;
    _web = null;
    _id = null;
    _textureId = null;
    await subscription?.cancel();
    try {
      if (web != null) await web.dispose().timeout(const Duration(seconds: 5));
      if (id != null) {
        await _bridge.invoke('dispose', id).timeout(const Duration(seconds: 5));
      }
    } catch (error) {
      _log(LumioLogLevel.warning, 'dispose_failed', _redact(error.toString()));
    }
    _notifySurface();
  }

  @override
  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    _cancelPending?.complete();
    if (_ready != null && !_ready!.isCompleted) {
      _ready!.completeError(StateError('Player disposed.'));
    }
    super.dispose();
    return _disposal = _close();
  }

  Future<void> _close() async {
    await _release();
    await _queue;
    await _logs.close();
  }
}
