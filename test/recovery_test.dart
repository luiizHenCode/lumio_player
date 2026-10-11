import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;

const recovery = LumioRecoveryConfiguration(
  enabled: true,
  maxAttempts: 2,
  initialDelay: Duration(milliseconds: 20),
  maxDelay: Duration(milliseconds: 40),
  stallTimeout: Duration(milliseconds: 120),
  stablePlaybackDuration: Duration(milliseconds: 60),
);
Future<void> flush([int milliseconds = 5]) =>
    Future<void>.delayed(Duration(milliseconds: milliseconds));

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeMock native;
  late LumioPlayerController player;
  final source = LumioSource.network(
    Uri.parse('https://example.com/live.m3u8'),
  );

  void create({
    LumioRecoveryConfiguration policy = recovery,
    LumioPlaybackMode mode = LumioPlaybackMode.live,
  }) {
    player = LumioPlayerController(
      recovery: policy,
      configuration: LumioPlayerConfiguration(
        mode: mode,
        engine: LumioPlaybackEngine.native,
        allowAutomaticFallback: false,
        initializationTimeout: const Duration(milliseconds: 200),
      ),
    );
  }

  Future<void> state(Map<String, Object?> data) async {
    await native.emit({'id': native.nextId - 1, 'type': 'state', ...data});
    await flush();
  }

  Future<void> error(
    String code, {
    Object? details,
    bool recoverable = true,
  }) async {
    await native.emit({
      'id': native.nextId - 1,
      'type': 'error',
      'code': code,
      'message': 'Playback failed',
      'details': details,
      'recoverable': recoverable,
    });
    await flush();
  }

  setUp(() {
    native = NativeMock()..install();
    create();
  });
  tearDown(() async {
    await player.dispose();
    native.uninstall();
  });

  test('configuration validates even when disabled', () {
    for (final config in [
      const LumioRecoveryConfiguration(maxAttempts: 0),
      const LumioRecoveryConfiguration(initialDelay: Duration.zero),
      const LumioRecoveryConfiguration(maxDelay: Duration.zero),
      const LumioRecoveryConfiguration(stallTimeout: Duration.zero),
      const LumioRecoveryConfiguration(stablePlaybackDuration: Duration.zero),
    ]) {
      expect(config.validate, throwsArgumentError);
    }
    expect(const LumioRecoveryConfiguration().enabled, isFalse);
  });

  test('disabled policy never retries a network error', () async {
    await player.dispose();
    create(policy: const LumioRecoveryConfiguration());
    await player.open(source);
    await error('ERROR_CODE_IO_NETWORK_CONNECTION_FAILED');
    await flush(180);
    expect(native.named('open'), hasLength(1));
    expect(player.value.error, isNotNull);
  });

  test(
    'buffering with playing false and no position progress recovers',
    () async {
      await player.open(source);
      await state({'playing': false, 'buffering': true});
      await flush(180);
      expect(native.named('open'), hasLength(2));
      expect(player.value.engine, LumioPlaybackEngine.native);
    },
  );

  test(
    'initialized alone does not reset budget or hide terminal stall',
    () async {
      await player.open(source);
      await flush(600);
      expect(native.named('open'), hasLength(3));
      expect(player.value.error?.code, 'live_position_stall');
      await flush(180);
      expect(native.named('open'), hasLength(3));
    },
  );

  test('manual retry renews an exhausted recovery budget', () async {
    await player.open(source);
    await error('network');
    await flush(35);
    await error('network');
    await flush(55);
    await error('network');
    await flush(60);
    expect(native.named('open'), hasLength(3));
    await player.retry();
    expect(native.named('open'), hasLength(4));
    await error('network');
    await flush(35);
    expect(native.named('open'), hasLength(5));
  });

  test('restarts preserve gain speed and requested autoplay', () async {
    await player.open(source);
    await player.setVolume(.4);
    await player.setSpeed(1.5);
    await error('ERROR_CODE_BEHIND_LIVE_WINDOW');
    await flush(35);
    final config =
        (native.named('open').last.arguments as Map)['config'] as Map;
    expect(config['volume'], .4);
    expect(config['speed'], 1.5);
    // A restart opens paused and restores the current intent after readiness.
    expect(config['autoPlay'], isFalse);
    expect(native.named('play'), hasLength(1));
  });

  test('bounded exponential backoff and initial Future still fails', () async {
    final times = <DateTime>[];
    native.intercept = (call) async {
      if (call.method == 'open') {
        times.add(DateTime.now());
        throw PlatformException(
          code: 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED',
        );
      }
      return native.respond(call);
    };
    await expectLater(player.open(source), throwsA(isA<LumioPlayerError>()));
    expect(player.value.error, isNotNull);
    await flush(150);
    expect(times, hasLength(3));
    expect(
      times[1].difference(times[0]).inMilliseconds,
      greaterThanOrEqualTo(20),
    );
    expect(
      times[2].difference(times[1]).inMilliseconds,
      greaterThanOrEqualTo(40),
    );
    expect(player.value.error?.code, 'ERROR_CODE_IO_NETWORK_CONNECTION_FAILED');
  });

  test('sustained position progress renews budget', () async {
    await player.open(source);
    await error('network');
    await flush(35);
    await error('network');
    await flush(55);
    for (var i = 1; i <= 5; i++) {
      await state({'positionMs': i * 1000});
      await flush(20);
    }
    await error('network');
    await flush(35);
    expect(native.named('open'), hasLength(4));
  });

  for (final code in [
    'auth',
    'http_401',
    'http_403',
    'http_404',
    'invalid_source',
    'unsupported_format',
    'ERROR_CODE_DECODING_FAILED',
  ]) {
    test('$code is terminal even when recoverable is true', () async {
      await player.open(source);
      await error(code);
      await flush(160);
      expect(native.named('open'), hasLength(1));
      expect(player.value.error?.code, code);
    });
  }

  test(
    'classified live segment 404 reloads and seeks live before play',
    () async {
      await player.open(source);
      await player.setVolume(.4);
      await player.setSpeed(1.5);
      await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
      await flush(35);
      expect(native.named('open'), hasLength(2));
      expect(native.named('seekToLive'), hasLength(1));
      expect(native.named('play'), hasLength(1));
      expect(
        native.calls.indexOf(native.named('seekToLive').single),
        lessThan(native.calls.indexOf(native.named('play').single)),
      );
      final config =
          (native.named('open').last.arguments as Map)['config'] as Map;
      expect(config['volume'], .4);
      expect(config['speed'], 1.5);
      expect(config['autoPlay'], isFalse);
      expect(player.value.engine, LumioPlaybackEngine.native);
    },
  );

  test('failed live seek never resumes playback during recovery', () async {
    await player.open(source);
    native.intercept = (call) async {
      if (call.method == 'seekToLive') {
        throw PlatformException(code: 'unsupported_live_seek');
      }
      return native.respond(call);
    };
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await flush(160);
    expect(native.named('open'), hasLength(2));
    expect(native.named('play'), isEmpty);
    expect(player.value.error?.code, 'unsupported_live_seek');
  });

  test('generic 404 in HTTP details remains terminal', () async {
    await player.open(source);
    await error('ERROR_CODE_IO_BAD_HTTP_STATUS', details: {'httpStatus': 404});
    await flush(160);
    expect(native.named('open'), hasLength(1));
    expect(native.named('seekToLive'), isEmpty);
  });

  test('classified segment error cannot recover VOD', () async {
    await player.dispose();
    create(mode: LumioPlaybackMode.video);
    await player.open(
      LumioSource.network(Uri.parse('https://example.com/video.mp4')),
    );
    await state({'live': false});
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await flush(160);
    expect(native.named('open'), hasLength(1));
    expect(native.named('seekToLive'), isEmpty);
  });

  test('classified segment recovery respects retry budget', () async {
    await player.open(source);
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await flush(35);
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await flush(55);
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await flush(60);
    expect(native.named('open'), hasLength(3));
    expect(native.named('seekToLive'), hasLength(2));
    expect(player.value.error?.code, 'hls_live_segment_unavailable');
  });

  test('pause cancels missing live segment recovery', () async {
    await player.open(source);
    await error('hls_live_segment_unavailable', details: {'httpStatus': 404});
    await player.pause();
    await flush(160);
    expect(native.named('open'), hasLength(1));
    expect(native.named('seekToLive'), isEmpty);
  });

  test(
    'classified segment without native recoverable flag is terminal',
    () async {
      await player.open(source);
      await error('hls_live_segment_unavailable', recoverable: false);
      await flush(160);
      expect(native.named('open'), hasLength(1));
    },
  );

  test(
    'classified iOS live interruption reloads and seeks live before play',
    () async {
      await player.open(source);
      await state({'initialized': false, 'buffering': true});
      await error(
        'ios_live_network_interruption',
        details: {
          'nativeErrorChain': [
            {'domain': 'AVFoundationErrorDomain', 'code': -11800},
            {'domain': 'NSURLErrorDomain', 'code': -1005},
          ],
          'errorLogStatusCodes': [404],
          'currentErrorLogStatusCodes': [],
        },
      );
      await flush(35);
      expect(native.named('open'), hasLength(2));
      expect(native.named('seekToLive'), hasLength(1));
      expect(native.named('play'), hasLength(1));
      expect(
        native.calls.indexOf(native.named('seekToLive').single),
        lessThan(native.calls.indexOf(native.named('play').single)),
      );
    },
  );

  test(
    'iOS terminal classification cannot be overridden by nested timeout',
    () async {
      await player.open(source);
      await error(
        'ios_native_terminal_error',
        recoverable: false,
        details: {
          'nativeCode': -11800,
          'nativeErrorChain': [
            {'domain': 'unknown', 'code': -1001},
          ],
        },
      );
      await flush(160);
      expect(native.named('open'), hasLength(1));
      expect(native.named('seekToLive'), isEmpty);
    },
  );

  test('classified iOS interruption cannot recover VOD', () async {
    await player.dispose();
    create(mode: LumioPlaybackMode.video);
    await player.open(source);
    await state({'live': false});
    await error('ios_live_network_interruption');
    await flush(160);
    expect(native.named('open'), hasLength(1));
  });

  test('iOS interruption respects budget and pause cancellation', () async {
    await player.open(source);
    await error('ios_live_network_interruption');
    await flush(35);
    await error('ios_live_network_interruption');
    await flush(55);
    await error('ios_live_network_interruption');
    await flush(60);
    expect(native.named('open'), hasLength(3));
    expect(native.named('seekToLive'), hasLength(2));
    expect(player.value.error?.code, 'ios_live_network_interruption');
    await player.retry();
    await error('ios_live_network_interruption');
    await player.pause();
    await flush(160);
    expect(native.named('open'), hasLength(4));
  });

  test(
    'classified iOS interruption respects disabled recovery policy',
    () async {
      await player.dispose();
      create(policy: const LumioRecoveryConfiguration());
      await player.open(source);
      await error('ios_live_network_interruption');
      await flush(160);
      expect(native.named('open'), hasLength(1));
    },
  );

  test('iOS native timeout is recognized with recoverable false', () async {
    await player.open(source);
    await error(
      'open_failed',
      details: {'nativeCode': -1001},
      recoverable: false,
    );
    await flush(35);
    expect(native.named('open'), hasLength(2));
  });

  test('HTTP status in native details overrides recoverable IO code', () async {
    await player.open(source);
    await error(
      'ERROR_CODE_IO_BAD_HTTP_STATUS',
      details: {'causeMessage': 'Response code: 403'},
    );
    await flush(160);
    expect(native.named('open'), hasLength(1));
  });

  test('terminal error cancels an already scheduled retry', () async {
    await player.open(source);
    await error('network');
    await error('codec');
    await flush(160);
    expect(native.named('open'), hasLength(1));
    expect(player.value.error?.code, 'codec');
  });

  test('pause immediately cancels a scheduled retry', () async {
    await player.open(source);
    await error('network');
    await player.pause();
    await flush(160);
    expect(native.named('open'), hasLength(1));
  });

  test(
    'one position jump is not sustained progress and cannot renew budget',
    () async {
      await player.open(source);
      await error('network');
      await flush(35);
      await error('network');
      await flush(55);
      await state({'positionMs': 1000});
      await error('network');
      await flush(70);
      expect(native.named('open'), hasLength(3));
      expect(player.value.error?.code, 'network');
    },
  );

  test('progressing buffering does not trigger the watchdog', () async {
    await player.open(source);
    for (var i = 1; i <= 8; i++) {
      await state({'playing': false, 'buffering': true, 'positionMs': i * 100});
      await flush(25);
    }
    expect(native.named('open'), hasLength(1));
  });

  test('manual retry cancels the earlier scheduled recovery', () async {
    await player.open(source);
    await error('network');
    await player.retry();
    await flush(70);
    expect(native.named('open'), hasLength(2));
  });

  test('engine selection cancels the earlier scheduled recovery', () async {
    await player.open(source);
    await error('network');
    await player.setEngine(LumioPlaybackEngine.native);
    await flush(70);
    expect(native.named('open'), hasLength(2));
  });

  test('new source invalidates old recovery', () async {
    await player.open(source);
    await error('network');
    await player.open(source, title: 'replacement');
    await player.pause();
    await flush(160);
    expect(native.named('open'), hasLength(2));
    expect(player.title, 'replacement');
  });

  test('VOD and local live sources are not recovered', () async {
    await player.dispose();
    create(mode: LumioPlaybackMode.video);
    await player.open(source);
    await error('network');
    await flush(160);
    expect(native.named('open'), hasLength(1));
    await player.dispose();
    create();
    await player.open(LumioSource.file('/video.ts'));
    await error('network');
    await flush(160);
    expect(native.named('open'), hasLength(2));
  });

  test('completed playback and disposal cancel watchdog/retry', () async {
    await player.open(source);
    await state({'completed': true});
    await flush(180);
    expect(native.named('open'), hasLength(1));
    await state({'completed': false});
    await error('network');
    await player.dispose();
    await flush(180);
    expect(native.named('open'), hasLength(1));
  });
}
