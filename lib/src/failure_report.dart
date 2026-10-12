import 'dart:convert';

import 'package:flutter/foundation.dart';

/// Privacy-safe snapshot of a failure, retained across retries and disposal.
/// No original exception, message, source, headers, or log text is included.
@immutable
class LumioFailureReport {
  LumioFailureReport({
    required this.timestamp,
    required this.code,
    required this.message,
    required Map<String, Object?> metadata,
  }) : metadata = _freeze(metadata) as Map<String, Object?>;

  /// UTC time at which the failure was observed (not report request time).
  final DateTime timestamp;

  /// Known public failure code, or `unknown_error` for unrecognized codes.
  final String code;

  /// Library-controlled description, never arbitrary native exception text.
  final String message;

  /// Deeply immutable, JSON-compatible failure-time metadata.
  final Map<String, Object?> metadata;

  String get formattedText =>
      'Lumio Player failure\n'
      'Time (UTC): ${timestamp.toUtc().toIso8601String()}\n'
      'Code: $code\n$message\n'
      '${const JsonEncoder.withIndent('  ').convert(metadata)}';

  static Object? _freeze(Object? value) {
    if (value is Map) {
      return Map<String, Object?>.unmodifiable({
        for (final entry in value.entries)
          entry.key as String: _freeze(entry.value),
      });
    }
    if (value is List) return List<Object?>.unmodifiable(value.map(_freeze));
    return value;
  }
}

// Exact value allowlists, not patterns: an apparently valid identifier may
// itself be a token or user name. The only non-enumerated strings admitted
// below are bounded, strictly numeric OS versions; all other strings drop.
String safeFailureCode(String code) =>
    _codes.contains(code) ? code : 'unknown_error';

const _codes = {
  'native_error',
  'network',
  'http_401',
  'http_403',
  'http_404',
  'auth',
  'codec',
  'decoder',
  'unsupported_format',
  'invalid_source',
  'invalid_argument',
  'open_failed',
  'event_channel',
  'initialization_failed',
  'initialization_timeout',
  'command_timeout',
  'live_position_stall',
  'unsupported_web_source',
  'unsupported_live_seek',
  'unsupported_volume_gain',
  'hls_live_segment_unavailable',
  'ios_live_network_interruption',
  'ios_native_terminal_error',
  // Fixed Dart WebView and bundled player.js event/failed-ACK codes only.
  // Internal JS exceptions (e.g. invalid_fit) map to command_failed.
  'media_failed',
  'webview_load_failed',
  'webview_setup_failed',
  'unsupported_source',
  'unsupported_headers',
  'unsupported_command',
  'not_ready',
  'playback_blocked',
  'media_error',
  'unsupported_hls',
  'hls_network_error',
  'hls_media_error',
  'open_cancelled',
  'command_failed',
  // Fixed native operation codes and AVFoundation failure phase.
  'engine_detached',
  'preview_seek_pending',
  'preview_seek_failed',
  'cancelled',
  'playback_failed',
  'not_initialized',
  'disposed',
  'seek_cancelled',
  'invalid_player',
  'asset_not_found',
  'file_not_found',
  'ERROR_CODE_UNSPECIFIED',
  'ERROR_CODE_REMOTE_ERROR',
  'ERROR_CODE_BEHIND_LIVE_WINDOW',
  'ERROR_CODE_TIMEOUT',
  'ERROR_CODE_FAILED_RUNTIME_CHECK',
  'ERROR_CODE_IO_UNSPECIFIED',
  'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
  'ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT',
  'ERROR_CODE_IO_INVALID_HTTP_CONTENT_TYPE',
  'ERROR_CODE_IO_BAD_HTTP_STATUS',
  'ERROR_CODE_IO_FILE_NOT_FOUND',
  'ERROR_CODE_IO_NO_PERMISSION',
  'ERROR_CODE_IO_CLEARTEXT_NOT_PERMITTED',
  'ERROR_CODE_IO_READ_POSITION_OUT_OF_RANGE',
  'ERROR_CODE_PARSING_CONTAINER_MALFORMED',
  'ERROR_CODE_PARSING_MANIFEST_MALFORMED',
  'ERROR_CODE_PARSING_CONTAINER_UNSUPPORTED',
  'ERROR_CODE_PARSING_MANIFEST_UNSUPPORTED',
  'ERROR_CODE_DECODER_INIT_FAILED',
  'ERROR_CODE_DECODER_QUERY_FAILED',
  'ERROR_CODE_DECODING_FAILED',
  'ERROR_CODE_DECODING_FORMAT_EXCEEDS_CAPABILITIES',
  'ERROR_CODE_DECODING_FORMAT_UNSUPPORTED',
  'ERROR_CODE_AUDIO_TRACK_INIT_FAILED',
  'ERROR_CODE_AUDIO_TRACK_WRITE_FAILED',
};

/// Strict, bounded structured projection shared by report details/diagnostics.
/// Free-form strings, keys, nested unknown objects and nonfinite numbers drop.
Map<String, Object?> safeFailureDiagnostics(Object? input, [int depth = 0]) {
  if (input is! Map || depth > 5) return {};
  final result = <String, Object?>{};
  for (final key in _numeric) {
    final value = input[key];
    if (value is num && value.isFinite && value.abs() <= (1 << 53)) {
      result[key] = value;
    }
  }
  for (final key in _boolean) {
    final value = input[key];
    if (value is bool) result[key] = value;
  }
  for (final entry in _enums.entries) {
    final value = input[entry.key];
    if (value is String && entry.value.contains(value)) {
      result[entry.key] = value;
    }
  }
  final code = input['code'];
  if (code is String) result['code'] = safeFailureCode(code);
  final sdkInt = input['sdkInt'];
  if (sdkInt is int && sdkInt > 0 && sdkInt <= 1000) {
    result['sdkInt'] = sdkInt;
  }
  // OS versions are the sole non-enumerated strings admitted. Bound both
  // length and components and require a full match (no suffix/newline/text).
  for (final key in const ['androidVersion', 'systemVersion']) {
    final version = input[key];
    if (version is String &&
        version.length <= 15 &&
        RegExp(r'[0-9]{1,3}(?:\.[0-9]{1,3}){0,3}').stringMatch(version) ==
            version) {
      result[key] = version;
    } else if (version is num &&
        version.isFinite &&
        version >= 0 &&
        version <= 999) {
      result[key] = version;
    }
  }
  for (final key in const [
    'player',
    'state',
    'media',
    'lastError',
    'details',
    'requestedBufferMs',
    'device',
    'startup',
  ]) {
    if (input[key] is Map) {
      result[key] = safeFailureDiagnostics(input[key], depth + 1);
    }
  }
  for (final key in const [
    'nativeErrorChain',
    'accessLog',
    'errorLog',
    'events',
  ]) {
    final value = input[key];
    if (value is List) {
      result[key] = value
          .take(30)
          .whereType<Map>()
          .map((item) => safeFailureDiagnostics(item, depth + 1))
          .toList();
    }
  }
  for (final key in const [
    'errorLogStatusCodes',
    'currentErrorLogStatusCodes',
  ]) {
    final value = input[key];
    if (value is List) {
      result[key] = value
          .take(30)
          .whereType<int>()
          .where((number) => number >= -999999 && number <= 999999)
          .toList();
    }
  }
  return result;
}

const _numeric = {
  'attempt',
  'elapsedMs',
  'createElapsedMs',
  'readinessElapsedMs',
  'firstFrameElapsedMs',
  'playbackStartedElapsedMs',
  'initializationTimeoutMs',
  'commandTimeoutMs',
  'errorCode',
  'nativeCode',
  'codeNumber',
  'httpStatus',
  'code',
  'statusCode',
  'playlistIndex',
  'playlistLength',
  'positionMs',
  'durationMs',
  'bufferedPositionMs',
  'width',
  'height',
  'volume',
  'speed',
  'videoBitrate',
  'audioBitrate',
  'frameRate',
  'audioSampleRate',
  'audioChannels',
  'bufferDurationMs',
  'liveOffsetMs',
  'droppedVideoFrames',
  'renderedVideoFrames',
  'liveTargetOffsetMs',
  'itemStatus',
  'timeControlStatus',
  'preferredForwardBufferDurationMs',
  'bufferMinMs',
  'bufferMaxMs',
  'bufferPlaybackMs',
  'bufferRebufferMs',
  'previewSeekTimeoutCount',
  'numberOfStalls',
  'numberOfDroppedVideoFrames',
  'observedBitrate',
  'indicatedBitrate',
  'numberOfBytesTransferred',
  'transferDuration',
  'durationWatched',
  'segmentsDownloadedDuration',
};
const _boolean = {
  'hasRenderedFirstFrame',
  'firstFrameSupported',
  'initialized',
  'playing',
  'buffering',
  'completed',
  'live',
  'recoverable',
  'nativeErrorChainComplete',
  'surfaceAvailable',
  'previewSeekPending',
  'handlesCropAndRotation',
  'allowBackgroundPlayback',
  'handlesAudioFocus',
  'supportsCustomHeaders',
  'enableDecoderFallback',
  'loopPlaylist',
  'audioSessionMixesWithOthers',
};
const _enums = {
  'stage': {
    'idle',
    'connecting',
    'preparing',
    'ready',
    'playing',
    'buffering',
    'recovering',
    'failed',
    'unknown',
    'unavailable',
  },
  'evidence': {
    'renderer',
    'pixelBuffer',
    'layerReady',
    'requestVideoFrameCallback',
    'loadedData',
  },
  'firstFrameEvidence': {
    'renderer',
    'pixelBuffer',
    'layerReady',
    'requestVideoFrameCallback',
    'loadedData',
  },
  'platform': {'Android', 'iOS', 'android', 'ios', 'web'},
  'domain': {
    'AVFoundationErrorDomain',
    'NSURLErrorDomain',
    'NSOSStatusErrorDomain',
  },
  'nativeErrorPhase': {'initialization', 'playback', 'open', 'ready'},
  'backend': {'AVQueuePlayer', 'ExoPlayer', 'Media3'},
  'sourceType': {'network', 'file', 'asset'},
  'sourceFormat': {'auto', 'hls', 'dash', 'progressive', 'rtsp'},
  'audioPolicy': {'preserveHost', 'mixWithOthers', 'exclusive'},
  'videoMimeType': {
    'video/avc',
    'video/hevc',
    'video/av01',
    'video/x-vnd.on2.vp9',
  },
  'audioMimeType': {
    'audio/mp4a-latm',
    'audio/mpeg',
    'audio/opus',
    'audio/ac3',
    'audio/eac3',
  },
};
