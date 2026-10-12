import 'package:flutter/widgets.dart';

enum LumioPlaybackEngine { automatic, native, webview }

enum LumioPlaybackMode { video, audio, live }

/// Texture supports Flutter surface capture; platform views do not.
enum LumioNativeViewType { texture, platformView }

/// Native audio policy. Explicit policies affect the shared iOS audio session.
enum LumioAudioPolicy {
  /// Leave the host audio session unchanged and do not request Android focus.
  preserveHost,

  /// Mix with other audio without requesting exclusive Android audio focus.
  mixWithOthers,

  /// Use iOS playback without mixing and Android Media3-managed audio focus.
  exclusive,
}

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
    this.nativeViewType = LumioNativeViewType.texture,
    this.mode = LumioPlaybackMode.video,
    this.audioPolicy = LumioAudioPolicy.preserveHost,
    this.allowBackgroundPlayback = false,
    this.autoPlay = true,
    this.looping = false,
    this.volume = 1,
    this.speed = 1,
    this.initializationTimeout = const Duration(seconds: 25),
    Duration? commandTimeout,
    this.buffer = const LumioBufferConfiguration(),
    this.allowAutomaticFallback = true,
    this.enableDecoderFallback = true,
    this.liveTargetOffset,
    // Keep the public named parameter while storing its nullable override privately.
    // ignore: prefer_initializing_formals
  }) : _commandTimeout = commandTimeout;
  final LumioPlaybackEngine engine;
  final LumioNativeViewType nativeViewType;
  final LumioPlaybackMode mode;
  final LumioAudioPolicy audioPolicy;

  /// Opt out of controller lifecycle pausing. The host must provide platform
  /// background support; this does not create a background service or PiP.
  final bool allowBackgroundPlayback;
  final bool autoPlay, looping, allowAutomaticFallback;
  final double volume, speed;

  /// Budget for create/open, readiness and playlist startup.
  final Duration initializationTimeout;
  final Duration? _commandTimeout;

  /// Deadline for commands and backend queries. When omitted, follows
  /// [initializationTimeout] for backwards compatibility.
  Duration get commandTimeout => _commandTimeout ?? initializationTimeout;
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
        initializationTimeout <= Duration.zero ||
        commandTimeout <= Duration.zero) {
      throw ArgumentError('Invalid volume, speed or timeout.');
    }
  }

  Map<String, Object?> toMap() => {
    'live': mode == LumioPlaybackMode.live,
    'audioPolicy': audioPolicy.name,
    'allowBackgroundPlayback': allowBackgroundPlayback,
    'autoPlay': autoPlay,
    'looping': looping,
    'volume': volume,
    'speed': speed,
    'initializationTimeoutMs': initializationTimeout.inMilliseconds,
    'commandTimeoutMs': commandTimeout.inMilliseconds,
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
  LumioLogEntry(
    this.level,
    this.code,
    this.message, {
    this.engine,
    this.playerId,
  }) : timestamp = DateTime.now();
  final DateTime timestamp;
  final LumioLogLevel level;
  final String code, message;
  final LumioPlaybackEngine? engine;

  /// Correlates controller logs across screen transitions without exposing media URLs.
  final int? playerId;
  @override
  String toString() =>
      '[Lumio/${level.name}/${engine?.name ?? 'controller'}${playerId == null ? '' : '/player-$playerId'}] $code: $message';
}

typedef LumioLogger = void Function(LumioLogEntry entry);

/// A known buffered interval; no continuity outside this interval is implied.
@immutable
class LumioBufferedRange {
  LumioBufferedRange({required this.start, required this.end}) {
    if (start.isNegative || end < start) {
      throw ArgumentError('Buffered ranges require 0 <= start <= end.');
    }
  }

  final Duration start, end;

  @override
  bool operator ==(Object other) =>
      other is LumioBufferedRange && other.start == start && other.end == end;

  @override
  int get hashCode => Object.hash(start, end);

  static List<LumioBufferedRange> parse(Object? value) {
    if (value is! List) return const [];
    return [
      for (final range in value)
        if (range is Map &&
            range['startMs'] is num &&
            range['endMs'] is num &&
            (range['startMs'] as num).isFinite &&
            (range['endMs'] as num).isFinite &&
            (range['startMs'] as num) >= 0 &&
            (range['endMs'] as num) >= (range['startMs'] as num))
          LumioBufferedRange(
            start: Duration(milliseconds: (range['startMs'] as num).toInt()),
            end: Duration(milliseconds: (range['endMs'] as num).toInt()),
          ),
    ];
  }
}

enum LumioPlaybackPhase {
  idle,
  connecting,
  preparing,
  ready,
  playing,
  buffering,
  recovering,
  failed,
}

/// Backend evidence, not a guarantee that pixels are visible on the host screen.
enum LumioFirstFrameEvidence {
  renderer,
  pixelBuffer,
  layerReady,
  requestVideoFrameCallback,
  loadedData;

  static LumioFirstFrameEvidence? parse(Object? value) {
    for (final evidence in values) {
      if (evidence.name == value) return evidence;
    }
    return null;
  }
}

/// State is owned by the controller. No native/plugin types leak into this API.
@immutable
class LumioPlayerState {
  LumioPlayerState({
    this.initialized = false,
    this.hasRenderedFirstFrame = false,
    this.firstFrameSupported = false,
    this.firstFrameEvidence,
    this.phase = LumioPlaybackPhase.idle,
    this.playing = false,
    this.buffering = false,
    this.completed = false,
    this.transitioning = false,
    this.live = false,
    this.position = Duration.zero,
    this.duration = Duration.zero,
    this.bufferedPosition = Duration.zero,
    List<LumioBufferedRange> buffered = const [],
    this.size = Size.zero,
    this.volume = 1,
    this.speed = 1,
    this.engine = LumioPlaybackEngine.native,
    this.playlistIndex = 0,
    this.playlistLength = 0,
    this.error,
  }) : buffered = List.unmodifiable(buffered);
  final bool initialized, playing, buffering, completed, transitioning, live;
  final bool hasRenderedFirstFrame, firstFrameSupported;
  final LumioFirstFrameEvidence? firstFrameEvidence;
  final LumioPlaybackPhase phase;
  final int playlistIndex, playlistLength;
  final Duration position, duration, bufferedPosition;

  /// Known buffered intervals only. Android may report just the interval from
  /// the current position to its buffered position; iOS/WebView report all
  /// available intervals. An empty list does not imply a legacy continuous range.
  final List<LumioBufferedRange> buffered;
  final Size size;
  final double volume, speed;
  final LumioPlaybackEngine engine;
  final LumioPlayerError? error;
  double get aspectRatio =>
      size.width > 0 && size.height > 0 ? size.width / size.height : 16 / 9;
  LumioPlayerState copyWith({
    bool? initialized,
    bool? hasRenderedFirstFrame,
    bool? firstFrameSupported,
    LumioFirstFrameEvidence? firstFrameEvidence,
    bool clearFirstFrame = false,
    LumioPlaybackPhase? phase,
    bool? playing,
    bool? buffering,
    bool? completed,
    bool? transitioning,
    bool? live,
    Duration? position,
    Duration? duration,
    Duration? bufferedPosition,
    List<LumioBufferedRange>? buffered,
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
    hasRenderedFirstFrame: clearFirstFrame
        ? false
        : hasRenderedFirstFrame ?? this.hasRenderedFirstFrame,
    firstFrameSupported: clearFirstFrame
        ? false
        : firstFrameSupported ?? this.firstFrameSupported,
    firstFrameEvidence: clearFirstFrame
        ? null
        : firstFrameEvidence ?? this.firstFrameEvidence,
    phase: phase ?? this.phase,
    playing: playing ?? this.playing,
    buffering: buffering ?? this.buffering,
    completed: completed ?? this.completed,
    transitioning: transitioning ?? this.transitioning,
    live: live ?? this.live,
    position: position ?? this.position,
    duration: duration ?? this.duration,
    bufferedPosition: bufferedPosition ?? this.bufferedPosition,
    buffered: buffered ?? this.buffered,
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
    final evidence = LumioFirstFrameEvidence.parse(event['firstFrameEvidence']);
    final supported = event['firstFrameSupported'] == true;
    final frame =
        supported && event['hasRenderedFirstFrame'] == true && evidence != null;
    return copyWith(
      firstFrameSupported: firstFrameSupported || supported,
      hasRenderedFirstFrame: hasRenderedFirstFrame || frame,
      firstFrameEvidence: hasRenderedFirstFrame
          ? firstFrameEvidence
          : frame
          ? evidence
          : null,
      buffered: event.containsKey('bufferedRanges')
          ? LumioBufferedRange.parse(event['bufferedRanges'])
          : null,
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
    this.nativePlatformView = false,
    this.supportsSurfaceCapture = false,
  });
  final LumioPlaybackEngine engine;

  /// False for iOS WebView: only mute/unmute is available, not fractional gain.
  final bool volumeControl;
  final bool nativePlaylist;

  /// Native platform-view rendering is available on this engine/platform.
  final bool nativePlatformView;

  /// Whether the selected surface can be captured by a RepaintBoundary.
  /// WebViews and native platform views cannot be captured this way.
  final bool supportsSurfaceCapture;
  final bool network, localFiles, assets, httpHeaders, detailedBufferControl;
  final Set<LumioMediaFormat> formats;
}
