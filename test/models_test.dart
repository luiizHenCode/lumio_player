import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

void main() {
  group('LumioSource', () {
    test('network validates absolute host and copies immutable headers', () {
      for (final uri in [
        'video.mp4',
        '/video.mp4',
        'https:///video',
        'file:///video',
      ]) {
        expect(() => LumioSource.network(Uri.parse(uri)), throwsArgumentError);
      }
      final headers = {'Authorization': 'Bearer secret'};
      final source = LumioSource.network(
        Uri.parse('https://user:password@example.com/video?token=secret'),
        headers: headers,
        format: LumioMediaFormat.hls,
      );
      headers['Authorization'] = 'changed';
      expect(source.headers['Authorization'], 'Bearer secret');
      expect(() => source.headers['extra'] = 'value', throwsUnsupportedError);
      expect(source.toMap(), {
        'type': 'network',
        'uri': source.uri,
        'headers': {'Authorization': 'Bearer secret'},
        'format': 'hls',
      });
      expect(source.toString(), 'LumioSource(network, hls)');
      expect(source.toString(), isNot(contains('secret')));
      expect(source.toString(), isNot(contains('password')));
    });

    test('file and asset validation and package serialization', () {
      expect(() => LumioSource.file(''), throwsArgumentError);
      expect(() => LumioSource.asset(''), throwsArgumentError);
      expect(
        () => LumioSource.asset('', package: 'media'),
        throwsArgumentError,
      );
      final file = LumioSource.file(
        '/tmp/video.mp4',
        format: LumioMediaFormat.progressive,
      );
      expect(file.toMap(), {
        'type': 'file',
        'uri': '/tmp/video.mp4',
        'headers': <String, String>{},
        'format': 'progressive',
      });
      expect(file.supportsWebView, isFalse);
      final asset = LumioSource.asset('assets/video.mp4', package: 'media');
      expect(asset.uri, 'packages/media/assets/video.mp4');
      expect(asset.type, LumioSourceType.asset);
      expect(asset.headers, isEmpty);
      expect(asset.supportsWebView, isFalse);
      expect(LumioSource.asset('video.mp4').uri, 'video.mp4');
    });

    test('URI credentials alone prevent WebView playback', () {
      for (final scheme in ['http', 'https']) {
        final publicSource = LumioSource.network(
          Uri.parse('$scheme://example.com/video?token=signed-query'),
        );
        expect(publicSource.supportsWebView, isTrue);
        for (final credentials in [
          'user',
          'user:password',
          ':password',
          'user%40name:pass%3Aword',
        ]) {
          final source = LumioSource.network(
            Uri.parse('$scheme://$credentials@example.com/video'),
          );
          expect(source.headers, isEmpty);
          expect(
            source.supportsWebView,
            isFalse,
            reason: '$scheme URI userInfo must not be passed to WebView',
          );
          expect(source.toString(), isNot(contains(credentials)));
        }
      }
    });

    test('web compatibility covers protocols, headers and every format', () {
      for (final scheme in ['http', 'https', 'rtsp', 'ftp']) {
        for (final format in LumioMediaFormat.values) {
          final source = LumioSource.network(
            Uri.parse('$scheme://example.com/video'),
            format: format,
          );
          expect(
            source.supportsWebView,
            ['http', 'https'].contains(scheme) &&
                ![
                  LumioMediaFormat.dash,
                  LumioMediaFormat.rtsp,
                ].contains(format),
            reason: '$scheme/${format.name}',
          );
        }
      }
      expect(
        LumioSource.network(
          Uri.parse('https://example.com/video'),
          headers: {'X-Test': 'value'},
        ).supportsWebView,
        isFalse,
      );
    });
  });

  group('configuration validation', () {
    test(
      'buffer defaults and valid equality/zero boundaries serialize in ms',
      () {
        const defaults = LumioBufferConfiguration();
        expect(defaults.validate, returnsNormally);
        expect(defaults.toMap(), {
          'bufferMinMs': 15000,
          'bufferMaxMs': 50000,
          'bufferPlaybackMs': 2500,
          'bufferRebufferMs': 5000,
        });
        for (final duration in [
          Duration.zero,
          const Duration(milliseconds: 7),
        ]) {
          final buffer = LumioBufferConfiguration(
            minimum: duration,
            maximum: duration,
            playback: duration,
            rebuffer: duration,
          );
          expect(buffer.validate, returnsNormally);
        }
      },
    );

    test('rejects each invalid buffer constraint', () {
      const negative = Duration(milliseconds: -1);
      const one = Duration(milliseconds: 1);
      const two = Duration(milliseconds: 2);
      const invalid = [
        LumioBufferConfiguration(minimum: negative),
        LumioBufferConfiguration(maximum: negative),
        LumioBufferConfiguration(playback: negative),
        LumioBufferConfiguration(rebuffer: negative),
        LumioBufferConfiguration(
          minimum: two,
          maximum: one,
          playback: one,
          rebuffer: one,
        ),
        LumioBufferConfiguration(minimum: one, playback: two, rebuffer: one),
        LumioBufferConfiguration(minimum: one, playback: one, rebuffer: two),
      ];
      for (final buffer in invalid) {
        expect(buffer.validate, throwsArgumentError);
      }
    });

    test('player defaults and live wire configuration', () {
      const defaults = LumioPlayerConfiguration();
      expect(defaults.validate, returnsNormally);
      expect(defaults.engine, LumioPlaybackEngine.automatic);
      expect(defaults.mode, LumioPlaybackMode.video);
      expect(defaults.allowAutomaticFallback, isTrue);
      expect(defaults.toMap(), {
        'live': false,
        'autoPlay': true,
        'looping': false,
        'volume': 1.0,
        'speed': 1.0,
        'initializationTimeoutMs': 25000,
        'enableDecoderFallback': true,
        ...defaults.buffer.toMap(),
      });
      const live = LumioPlayerConfiguration(
        mode: LumioPlaybackMode.live,
        autoPlay: false,
        looping: true,
        volume: 0,
        speed: 0.25,
        initializationTimeout: Duration(milliseconds: 123),
      );
      expect(live.validate, returnsNormally);
      expect(live.toMap()['live'], isTrue);
      expect(live.toMap()['initializationTimeoutMs'], 123);
      expect(live.toMap()['autoPlay'], isFalse);
      expect(live.toMap()['looping'], isTrue);
      expect(
        const LumioPlayerConfiguration(
          mode: LumioPlaybackMode.audio,
        ).toMap()['live'],
        isFalse,
      );
    });

    test('native live offset and decoder fallback serialize explicitly', () {
      const config = LumioPlayerConfiguration(
        liveTargetOffset: Duration(seconds: 3),
        enableDecoderFallback: false,
      );
      expect(config.validate, returnsNormally);
      expect(config.toMap()['liveTargetOffsetMs'], 3000);
      expect(config.toMap()['enableDecoderFallback'], false);
      expect(
        const LumioPlayerConfiguration(
          liveTargetOffset: Duration(seconds: -1),
        ).validate,
        throwsArgumentError,
      );
      expect(
        const LumioPlayerConfiguration(
          liveTargetOffset: Duration(seconds: 61),
        ).validate,
        throwsArgumentError,
      );
    });

    test('rejects invalid volume, speed, timeout and nested buffer', () {
      for (final volume in [
        -0.01,
        1.01,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        final config = LumioPlayerConfiguration(volume: volume);
        expect(config.validate, throwsArgumentError);
        expect(
          () => LumioPlayerController(configuration: config),
          throwsArgumentError,
        );
      }
      for (final speed in [
        0.0,
        -0.01,
        double.nan,
        double.infinity,
        double.negativeInfinity,
      ]) {
        expect(
          LumioPlayerConfiguration(speed: speed).validate,
          throwsArgumentError,
        );
      }
      for (final timeout in [Duration.zero, const Duration(milliseconds: -1)]) {
        expect(
          LumioPlayerConfiguration(initializationTimeout: timeout).validate,
          throwsArgumentError,
        );
      }
      expect(
        const LumioPlayerConfiguration(
          buffer: LumioBufferConfiguration(playback: Duration(seconds: 16)),
        ).validate,
        throwsArgumentError,
      );
      expect(
        const LumioPlayerConfiguration(volume: 1, speed: 100).validate,
        returnsNormally,
      );
    });
  });

  group('LumioPlayerState', () {
    test('defaults and aspect ratio fallback for zero/invalid size', () {
      const state = LumioPlayerState();
      expect(state.initialized, isFalse);
      expect(state.playing, isFalse);
      expect(state.buffering, isFalse);
      expect(state.completed, isFalse);
      expect(state.transitioning, isFalse);
      expect(state.live, isFalse);
      expect(state.position, Duration.zero);
      expect(state.duration, Duration.zero);
      expect(state.bufferedPosition, Duration.zero);
      expect(state.volume, 1);
      expect(state.speed, 1);
      expect(state.engine, LumioPlaybackEngine.native);
      expect(state.error, isNull);
      for (final size in [
        Size.zero,
        const Size(0, 10),
        const Size(10, 0),
        const Size(-1, 10),
      ]) {
        expect(state.copyWith(size: size).aspectRatio, 16 / 9);
      }
      expect(state.copyWith(size: const Size(640, 480)).aspectRatio, 4 / 3);
    });

    test(
      'copyWith retains fields, replaces error and explicitly clears it',
      () {
        const error = LumioPlayerError(code: 'first', message: 'Failure');
        const replacement = LumioPlayerError(code: 'second', message: 'Other');
        const state = LumioPlayerState(
          initialized: true,
          playing: true,
          buffering: true,
          completed: true,
          transitioning: true,
          live: true,
          position: Duration(seconds: 1),
          duration: Duration(seconds: 2),
          bufferedPosition: Duration(seconds: 3),
          size: Size(100, 50),
          volume: 0.5,
          speed: 1.5,
          engine: LumioPlaybackEngine.webview,
          error: error,
        );
        final copy = state.copyWith(playing: false, volume: 0);
        expect(copy.initialized, state.initialized);
        expect(copy.playing, isFalse);
        expect(copy.buffering, state.buffering);
        expect(copy.completed, state.completed);
        expect(copy.transitioning, state.transitioning);
        expect(copy.live, state.live);
        expect(copy.position, state.position);
        expect(copy.duration, state.duration);
        expect(copy.bufferedPosition, state.bufferedPosition);
        expect(copy.size, state.size);
        expect(copy.volume, 0);
        expect(copy.speed, state.speed);
        expect(copy.engine, state.engine);
        expect(copy.error, same(error));
        expect(state.copyWith(error: replacement).error, same(replacement));
        expect(state.copyWith(error: null).error, same(error));
        expect(
          state.copyWith(clearError: true, error: replacement).error,
          isNull,
        );
        expect(state.playing, isTrue);
      },
    );

    test('partial events merge numeric fields without discarding state', () {
      const error = LumioPlayerError(code: 'test', message: 'Failure');
      const initial = LumioPlayerState(
        initialized: true,
        transitioning: true,
        duration: Duration(seconds: 10),
        size: Size(320, 240),
        engine: LumioPlaybackEngine.webview,
        error: error,
      );
      final applied = initial.apply({
        'type': 'state',
        'playing': true,
        'buffering': true,
        'completed': true,
        'live': true,
        'positionMs': 123.9,
        'bufferedPositionMs': 456,
        'width': 640,
        'volume': 0,
        'speed': 2,
      });
      expect(applied.initialized, isTrue);
      expect(applied.playing, isTrue);
      expect(applied.buffering, isTrue);
      expect(applied.completed, isTrue);
      expect(applied.live, isTrue);
      expect(applied.transitioning, isTrue);
      expect(applied.position, const Duration(milliseconds: 123));
      expect(applied.duration, initial.duration);
      expect(applied.bufferedPosition, const Duration(milliseconds: 456));
      expect(applied.size, const Size(640, 240));
      expect(applied.volume, 0);
      expect(applied.speed, 2);
      expect(applied.engine, initial.engine);
      expect(applied.error, same(error));
      expect(initial.position, Duration.zero);
      expect(
        applied.apply({'playing': false, 'initialized': false}).playing,
        isFalse,
      );
      expect(applied.apply({'volume': null}).volume, 0);
    });
  });

  test(
    'error and log entries retain public metadata with predictable formatting',
    () {
      const error = LumioPlayerError(
        code: 'decoder',
        message: 'Failed',
        details: {'attempt': 1},
        recoverable: true,
        engine: LumioPlaybackEngine.native,
      );
      expect(error, isA<Exception>());
      expect(error.toString(), 'LumioPlayerError(decoder): Failed');
      expect(error.details, {'attempt': 1});
      expect(error.recoverable, isTrue);
      expect(error.engine, LumioPlaybackEngine.native);
      final before = DateTime.now();
      final entry = LumioLogEntry(
        LumioLogLevel.warning,
        'fallback',
        'Trying web',
        engine: LumioPlaybackEngine.webview,
      );
      expect(entry.timestamp.isBefore(before), isFalse);
      expect(entry.timestamp.isAfter(DateTime.now()), isFalse);
      expect(entry.toString(), '[Lumio/warning/webview] fallback: Trying web');
      expect(
        LumioLogEntry(LumioLogLevel.info, 'ready', 'Ready').toString(),
        '[Lumio/info/controller] ready: Ready',
      );
    },
  );
}
