import 'package:flutter/widgets.dart';

enum LumioPlaybackEngine { automatic, native, webview }

enum LumioPlaybackMode { video, audio, live }

enum LumioSourceType { network, file, asset }

enum LumioMediaFormat { auto, hls, dash, progressive, rtsp }

enum LumioLogLevel { debug, info, warning, error }

/// Immutable source. Credentials are deliberately omitted from toString/logs.
class LumioSource {
  LumioSource.network(
    Uri uri, {
    Map<String, String> headers = const {},
    this.format = LumioMediaFormat.auto,
  }) : type = LumioSourceType.network,
       uri = uri.toString(),
       headers = Map.unmodifiable(headers) {
    if (!uri.hasScheme || uri.host.isEmpty) {
      throw ArgumentError(
        'A network source requires an absolute URI with a host.',
      );
    }
  }
  LumioSource.file(this.uri, {this.format = LumioMediaFormat.auto})
    : type = LumioSourceType.file,
      headers = const {} {
    if (uri.isEmpty) throw ArgumentError('File path cannot be empty.');
  }
  LumioSource.asset(
    String asset, {
    String? package,
    this.format = LumioMediaFormat.auto,
  }) : uri = package == null ? asset : 'packages/$package/$asset',
       type = LumioSourceType.asset,
       headers = const {} {
    if (asset.isEmpty) throw ArgumentError('Asset key cannot be empty.');
  }
  final LumioSourceType type;
  final String uri;
  final Map<String, String> headers;
  final LumioMediaFormat format;
  bool get supportsWebView =>
      type == LumioSourceType.network &&
      headers.isEmpty &&
      Uri.parse(uri).userInfo.isEmpty &&
      {'http', 'https'}.contains(Uri.parse(uri).scheme) &&
      format != LumioMediaFormat.rtsp &&
      format != LumioMediaFormat.dash;
  Map<String, Object?> toMap() => {
    'type': type.name,
    'uri': uri,
    'headers': headers,
    'format': format.name,
  };
  @override
  String toString() => 'LumioSource(${type.name}, ${format.name})';
}

/// A titled entry in a native queue (or a controller-managed WebView sequence).
@immutable
class LumioPlaylistItem {
  const LumioPlaylistItem({required this.source, this.title});
  final LumioSource source;
  final String? title;
}

@immutable
class LumioPlaylist {
  LumioPlaylist(List<LumioPlaylistItem> items, {this.loop = false})
    : items = List.unmodifiable(items) {
    if (items.isEmpty) {
      throw ArgumentError('A playlist must contain at least one item.');
    }
  }
  final List<LumioPlaylistItem> items;

  /// Repeat the queue. Item looping takes precedence over queue looping.
  final bool loop;
}

class LumioBufferConfiguration {
  const LumioBufferConfiguration({
    this.minimum = const Duration(seconds: 15),
    this.maximum = const Duration(seconds: 50),
    this.playback = const Duration(milliseconds: 2500),
    this.rebuffer = const Duration(seconds: 5),
  });
  final Duration minimum, maximum, playback, rebuffer;
  void validate() {
    if (minimum.isNegative ||
        maximum < minimum ||
        playback.isNegative ||
        rebuffer.isNegative ||
        playback > minimum ||
        rebuffer > minimum) {
      throw ArgumentError(
        'Buffer durations require 0 <= playback/rebuffer <= minimum <= maximum.',
      );
    }
  }

  Map<String, Object?> toMap() => {
    'bufferMinMs': minimum.inMilliseconds,
    'bufferMaxMs': maximum.inMilliseconds,
    'bufferPlaybackMs': playback.inMilliseconds,
    'bufferRebufferMs': rebuffer.inMilliseconds,
  };
}

class LumioPlayerConfiguration {
  const LumioPlayerConfiguration({
    this.engine = LumioPlaybackEngine.automatic,
    this.mode = LumioPlaybackMode.video,
    this.autoPlay = true,
    this.looping = false,
    this.volume = 1,
    this.speed = 1,
    this.initializationTimeout = const Duration(seconds: 25),
    this.buffer = const LumioBufferConfiguration(),
    this.allowAutomaticFallback = true,
    this.enableDecoderFallback = true,
    this.liveTargetOffset,
  });
  final LumioPlaybackEngine engine;
  final LumioPlaybackMode mode;
  final bool autoPlay, looping, allowAutomaticFallback;
  final double volume, speed;
  final Duration initializationTimeout;
  final LumioBufferConfiguration buffer;

  /// Android Media3 options. iOS reports them as unsupported in diagnostics.
  final bool enableDecoderFallback;
  final Duration? liveTargetOffset;
  void validate() {
    buffer.validate();
    if (liveTargetOffset != null &&
        (liveTargetOffset!.isNegative ||
            liveTargetOffset! > const Duration(seconds: 60))) {
      throw ArgumentError(
        'Live target offset must be between 0 and 60 seconds.',
      );
    }
    if (!volume.isFinite ||
        volume < 0 ||
        volume > 1 ||
        !speed.isFinite ||
        speed <= 0 ||
        initializationTimeout <= Duration.zero) {
      throw ArgumentError('Invalid volume, speed or initialization timeout.');
    }
  }

  Map<String, Object?> toMap() => {
    'live': mode == LumioPlaybackMode.live,
    'autoPlay': autoPlay,
    'looping': looping,
    'volume': volume,
    'speed': speed,
    'initializationTimeoutMs': initializationTimeout.inMilliseconds,
    'enableDecoderFallback': enableDecoderFallback,
    if (liveTargetOffset != null)
      'liveTargetOffsetMs': liveTargetOffset!.inMilliseconds,
    ...buffer.toMap(),
  };
}

class LumioPlayerError implements Exception {
  const LumioPlayerError({
    required this.code,
    required this.message,
    this.details,
    this.recoverable = false,
    this.engine,
  });
  final String code, message;
  final Object? details;
  final bool recoverable;
  final LumioPlaybackEngine? engine;
  @override
  String toString() => 'LumioPlayerError($code): $message';
}

class LumioLogEntry {
  LumioLogEntry(this.level, this.code, this.message, {this.engine})
    : timestamp = DateTime.now();
  final DateTime timestamp;
  final LumioLogLevel level;
  final String code, message;
  final LumioPlaybackEngine? engine;
  @override
  String toString() =>
      '[Lumio/${level.name}/${engine?.name ?? 'controller'}] $code: $message';
}

typedef LumioLogger = void Function(LumioLogEntry entry);

/// State is owned by the controller. No native/plugin types leak into this API.
@immutable
class LumioPlayerState {
  const LumioPlayerState({
    this.initialized = false,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.transitioning = false,
    this.live = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    this.size = Size.zero,
    this.volume = 1,
    this.speed = 1,
    this.engine = LumioPlaybackEngine.native,
    this.playlistIndex = 0,
    this.playlistLength = 0,
    this.error,
  });
  final bool initialized, playing, buffering, completed, transitioning, live;
  final int playlistIndex, playlistLength;
  final Duration position, duration, bufferedPosition;
  final Size size;
  final double volume, speed;
  final LumioPlaybackEngine engine;
  final LumioPlayerError? error;
  double get aspectRatio =>
      size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9;
  LumioPlayerState copyWith({
    bool? initialized,
    bool? playing,
    bool? buffering,
    bool? completed,
    bool? transitioning,
    bool? live,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    Size? size,
    double? volume,
    double? speed,
    LumioPlaybackEngine? engine,
    int? playlistIndex,
    int? playlistLength,
    LumioPlayerError? error,
    bool clearError = false,
  }) => LumioPlayerState(
    initialized: initialized ?? this.initialized,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    transitioning: transitioning ?? this.transitioning,
    live: live ?? this.live,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    size: size ?? this.size,
    volume: volume ?? this.volume,
    speed: speed ?? this.speed,
    engine: engine ?? this.engine,
    playlistIndex: playlistIndex ?? this.playlistIndex,
    playlistLength: playlistLength ?? this.playlistLength,
    error: clearError ? null : error ?? this.error,
  );
  LumioPlayerState apply(Map<String, dynamic> event) {
    double number(String key, double fallback) =>
        (event[key] as num?)?.toDouble() ?? fallback;
    return copyWith(
      initialized: event['initialized'] as bool?,
      playing: event['playing'] as bool?,
      buffering: event['buffering'] as bool?,
      completed: event['completed'] as bool?,
      live: event['live'] as bool?,
      playlistIndex: (event['playlistIndex'] as num?)?.toInt(),
      playlistLength: (event['playlistLength'] as num?)?.toInt(),
      position: Duration(
        milliseconds: number(
          'positionMs',
          position.inMilliseconds.toDouble(),
        ).toInt(),
      ),
      duration: Duration(
        milliseconds: number(
          'durationMs',
          duration.inMilliseconds.toDouble(),
        ).toInt(),
      ),
      bufferedPosition: Duration(
        milliseconds: number(
          'bufferedPositionMs',
          bufferedPosition.inMilliseconds.toDouble(),
        ).toInt(),
      ),
      size: Size(number('width', size.width), number('height', size.height)),
      volume: number('volume', volume),
      speed: number('speed', speed),
    );
  }
}

class LumioCapabilities {
  const LumioCapabilities({
    required this.engine,
    required this.network,
    required this.localFiles,
    required this.assets,
    required this.httpHeaders,
    required this.formats,
    required this.detailedBufferControl,
    this.volumeControl = true,
    this.nativePlaylist = true,
  });
  final LumioPlaybackEngine engine;

  /// False for iOS WebView: only mute/unmute is available, not fractional gain.
  final bool volumeControl;
  final bool nativePlaylist;
  final bool network, localFiles, assets, httpHeaders, detailedBufferControl;
  final Set<LumioMediaFormat> formats;
}
