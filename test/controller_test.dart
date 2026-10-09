import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

const _methods = MethodChannel('lumio_player/methods');
const _events = MethodChannel('lumio_player/events');
const _codec = StandardMethodCodec();

/// Models the platform side of receiveBroadcastStream, including subscription
/// handshakes. Events must go through the installed binary message handler.
class NativeMock {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final eventCalls = <String>[];
  int nextId = 1;
  bool initialize = true;
  Future<Object?> Function(MethodCall)? intercept;

  void install() {
    messenger.setMockMethodCallHandler(_events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (intercept != null) return intercept!(call);
      return respond(call);
    });
  }

  Future<Object?> respond(MethodCall call) async {
    if (call.method == 'create') {
      final id = nextId++;
      return {'id': id, 'textureId': id + 100};
    }
    if (call.method == 'open' && initialize) {
      final args = Map<String, dynamic>.from(call.arguments as Map);
      await emit({
        'id': args['id'],
        'type': 'state',
        'initialized': true,
        'buffering': false,
        'playing': (args['config'] as Map)['autoPlay'],
      });
    }
    return null;
  }

  Future<void> emit(Map<String, Object?> event) =>
      send(_codec.encodeSuccessEnvelope(event));

  Future<void> send(ByteData data) {
    unawaited(messenger.handlePlatformMessage(_events.name, data, null));
    return SynchronousFuture<void>(null);
  }

  List<MethodCall> named(String name) =>
      calls.where((call) => call.method == name).toList();

  void uninstall() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_events, null);
  }
}

// These are asynchronous unit tests, not widget tests: platform reply futures
// run on the real event loop. A turn flushes channel delivery and queued work.
class _Clock {
  Future<void> pump([Duration duration = Duration.zero]) async {
    await Future<void>.delayed(duration);
    await Future<void>.delayed(Duration.zero);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeMock native;
  late List<LumioPlayerController> players;

  LumioPlayerController player({
    LumioPlaybackEngine engine = LumioPlaybackEngine.native,
    LumioLogger? logger,
    bool fallback = false,
    bool autoPlay = true,
    Duration initializationTimeout = const Duration(seconds: 1),
  }) {
    final controller = LumioPlayerController(
      configuration: LumioPlayerConfiguration(
        engine: engine,
        allowAutomaticFallback: fallback,
        initializationTimeout: initializationTimeout,
        autoPlay: autoPlay,
      ),
      logger: logger,
    );
    players.add(controller);
    return controller;
  }

  final source = LumioSource.network(
    Uri.parse('https://example.com/video.mp4'),
  );

  setUp(() {
    native = NativeMock()..install();
    players = [];
  });

  Future<void> finish(_Clock tester) async {
    for (final controller in players) {
      final closing = controller.dispose();
      await tester.pump();
      await closing;
    }

    debugDefaultTargetPlatformOverride = null;
    native.uninstall();
  }

  Future<void> open(_Clock tester, LumioPlayerController controller) async {
    final opening = controller.open(source);
    await tester.pump();
    await opening;
  }

  test('native create/open captures early events and updates state', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    var notifications = 0;
    controller.addListener(() => notifications++);
    await open(tester, controller);
    expect(native.eventCalls, ['listen']);
    expect(native.calls.map((c) => c.method), ['create', 'open']);
    expect(controller.source, same(source));
    expect(controller.textureId, 101);
    expect(controller.webViewController, isNull);
    expect(controller.value.initialized, isTrue);
    expect(controller.value.transitioning, isFalse);
    expect(controller.value.playing, isTrue);
    expect(controller.value.error, isNull);
    expect(native.named('open').single.arguments, {
      'id': 1,
      'source': source.toMap(),
      'config': controller.configuration.toMap(),
    });
    await native.emit({
      'id': 1,
      'type': 'state',
      'playing': false,
      'buffering': true,
      'completed': true,
      'live': true,
      'positionMs': 1234,
      'durationMs': 9000,
      'bufferedPositionMs': 4567,
      'width': 1920,
      'height': 1080,
      'volume': 0.4,
      'speed': 1.5,
    });
    await tester.pump();
    final state = controller.value;
    expect(state.playing, isFalse);
    expect(state.buffering, isTrue);
    expect(state.completed, isTrue);
    expect(state.live, isTrue);
    expect(state.position, const Duration(milliseconds: 1234));
    expect(state.duration, const Duration(seconds: 9));
    expect(state.bufferedPosition, const Duration(milliseconds: 4567));
    expect(state.aspectRatio, 16 / 9);
    expect(state.volume, 0.4);
    expect(state.speed, 1.5);
    expect(notifications, greaterThan(2));
  });

  test('commands serialize arguments and persist settings on reopen', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await open(tester, controller);
    final commands = Future.wait([
      controller.play(),
      controller.pause(),
      controller.seekTo(const Duration(milliseconds: 321)),
      controller.setVolume(0.25),
      controller.setSpeed(1.75),
      controller.setLooping(true),
    ]);
    await tester.pump();
    await commands;
    expect(native.calls.skip(2).map((c) => c.method), [
      'play',
      'pause',
      'seek',
      'volume',
      'speed',
      'looping',
    ]);
    expect(native.named('seek').single.arguments, {'id': 1, 'positionMs': 321});
    expect(native.named('volume').single.arguments, {'id': 1, 'volume': 0.25});
    expect(native.named('speed').single.arguments, {'id': 1, 'speed': 1.75});
    expect(native.named('looping').single.arguments, {
      'id': 1,
      'looping': true,
    });
    expect(controller.value.volume, 0.25);
    expect(controller.value.speed, 1.75);
    expect(controller.looping, isTrue);
    await open(tester, controller);
    expect(native.named('dispose').single.arguments, {'id': 1});
    final config =
        (native.named('open').last.arguments as Map)['config'] as Map;
    expect(config['volume'], 0.25);
    expect(config['speed'], 1.75);
    expect(config['looping'], isTrue);
  });

  test('seekToLive rejects VOD and routes live command to native', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await open(tester, controller);
    await expectLater(
      controller.seekToLive(),
      throwsA(
        isA<LumioPlayerError>().having(
          (error) => error.code,
          'code',
          'unsupported_live_seek',
        ),
      ),
    );
    expect(native.named('seekToLive'), isEmpty);
    await native.emit({'id': 1, 'type': 'state', 'live': true});
    await tester.pump();
    final seeking = controller.seekToLive();
    await tester.pump();
    await seeking;
    expect(native.named('seekToLive').single.arguments, {'id': 1});
  });

  test('invalid commands and uninitialized use do not reach native', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await expectLater(controller.play(), throwsStateError);
    await expectLater(controller.retry(), throwsStateError);
    await open(tester, controller);
    final count = native.calls.length;
    await expectLater(
      controller.seekTo(const Duration(milliseconds: -1)),
      throwsArgumentError,
    );
    for (final volume in [-0.1, 1.1, double.nan, double.infinity]) {
      await expectLater(controller.setVolume(volume), throwsArgumentError);
    }
    for (final speed in [0.0, -1.0, double.nan, double.infinity]) {
      await expectLater(controller.setSpeed(speed), throwsArgumentError);
    }
    expect(native.calls.length, count);
    final pause = controller.pause();
    await tester.pump();
    await pause;
  });

  test(
    'a blocked command prevents later commands, failure does not poison queue',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      await open(tester, controller);
      final gate = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'play' ? gate.future : native.respond(call);
      final playing = expectLater(
        controller.play(),
        throwsA(isA<LumioPlayerError>()),
      );
      final pausing = controller.pause();
      await tester.pump();
      expect(native.named('pause'), isEmpty);
      gate.completeError(
        PlatformException(code: 'command_failed', message: 'Failed'),
      );
      await tester.pump();
      await playing;
      await pausing;
      expect(native.named('pause'), hasLength(1));
      expect(controller.value.error, isNull);
    },
  );

  test('multiple players share listen and route only matching ids', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final first = player();
    final second = player();
    await open(tester, first);
    await open(tester, second);
    expect(native.eventCalls, ['listen']);
    await native.emit({'id': 2, 'type': 'state', 'positionMs': 500});
    await native.emit({'id': 999, 'type': 'state', 'positionMs': 999});
    await tester.pump();
    expect(first.value.position, Duration.zero);
    expect(second.value.position, const Duration(milliseconds: 500));
    final closing = first.dispose();
    await tester.pump();
    await closing;
    expect(native.eventCalls, ['listen']);
    await native.emit({'id': 1, 'type': 'state', 'positionMs': 777});
    await native.emit({'id': 2, 'type': 'state', 'positionMs': 600});
    await tester.pump();
    expect(first.value.position, Duration.zero);
    expect(second.value.position, const Duration(milliseconds: 600));
    final lastClosing = second.dispose();
    await tester.pump();
    await lastClosing;
    expect(native.eventCalls, ['listen', 'cancel']);
  });

  test(
    'dispose is idempotent, closes logs and rejects later operations',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      final logDone = Completer<void>();
      controller.logs.listen((_) {}, onDone: logDone.complete);
      await open(tester, controller);
      final closing = controller.dispose();
      expect(controller.dispose(), same(closing));
      await tester.pump();
      await closing;
      await logDone.future;
      expect(controller.textureId, isNull);
      expect(native.named('dispose'), hasLength(1));
      expect(native.eventCalls, ['listen', 'cancel']);
      await expectLater(controller.play(), throwsStateError);
      await expectLater(controller.open(source), throwsStateError);
      await expectLater(controller.diagnostics(), throwsStateError);
    },
  );

  test(
    'dispose cancels initialization waiting for state and queued commands',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      native.initialize = false;
      final controller = player();
      final opening = expectLater(controller.open(source), throwsStateError);
      final queued = expectLater(controller.play(), throwsStateError);
      await tester.pump();
      final closing = controller.dispose();
      await tester.pump();
      await Future.wait([opening, queued, closing]);
      expect(native.named('play'), isEmpty);
      expect(native.named('dispose').single.arguments, {'id': 1});
    },
  );

  test('dispose during create releases the late native player', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final gate = Completer<Object?>();
    native.intercept = (call) =>
        call.method == 'create' ? gate.future : native.respond(call);
    final controller = player();
    var openCancelled = false;
    final opening = expectLater(
      controller.open(source),
      throwsStateError,
    ).then((_) => openCancelled = true);
    await tester.pump();
    expect(native.named('create'), hasLength(1));
    var disposalCompleted = false;
    final closing = controller.dispose().then((_) => disposalCompleted = true);
    await tester.pump();
    final cancelledBeforeCreateReply = openCancelled;
    final disposedBeforeCreateReply = disposalCompleted;
    final callsBeforeCreateReply = native.calls
        .map((call) => call.method)
        .toList();
    // Release the gate before asserting, including when cancellation regresses.
    gate.complete({'id': 42, 'textureId': 142});
    await tester.pump();
    await Future.wait([opening, closing]);
    expect(
      cancelledBeforeCreateReply,
      isTrue,
      reason:
          'dispose must cancel open without waiting for create or its timeout',
    );
    expect(disposedBeforeCreateReply, isTrue);
    expect(callsBeforeCreateReply, ['create']);
    expect(native.eventCalls, ['listen', 'cancel']);
    expect(native.named('open'), isEmpty);
    expect(native.named('dispose').single.arguments, {'id': 42});
    expect(controller.textureId, isNull);
  });

  test('reopen ignores stale ids and retry restores VOD position', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await open(tester, controller);
    await native.emit({
      'id': 1,
      'type': 'state',
      'positionMs': 1200,
      'playing': false,
    });
    final retry = controller.retry();
    await tester.pump();
    await retry;
    expect(native.named('seek').single.arguments, {
      'id': 2,
      'positionMs': 1200,
    });
    await native.emit({
      'id': 1,
      'type': 'error',
      'code': 'stale',
      'message': 'Old player',
    });
    await tester.pump();
    expect(controller.value.error, isNull);
  });

  test(
    'native initialization errors are typed, release player and allow retry',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      native.intercept = (call) async {
        if (call.method == 'open') {
          await native.emit({
            'id': 1,
            'type': 'error',
            'code': 'decoder_failed',
            'message': 'No decoder',
            'details': 'Unsupported codec',
            'recoverable': true,
          });
          return null;
        }
        return native.respond(call);
      };
      final controller = player();
      final failed = expectLater(
        controller.open(source),
        throwsA(
          isA<LumioPlayerError>()
              .having((e) => e.code, 'code', 'decoder_failed')
              .having((e) => e.recoverable, 'recoverable', true)
              .having((e) => e.engine, 'engine', LumioPlaybackEngine.native),
        ),
      );
      await tester.pump();
      await failed;
      expect(controller.value.transitioning, isFalse);
      expect(controller.value.buffering, isFalse);
      expect(controller.textureId, isNull);
      expect(native.named('dispose'), hasLength(1));
      native.intercept = null;
      final retry = controller.retry();
      await tester.pump();
      await retry;
      expect(controller.value.error, isNull);
    },
  );

  test(
    'platform open errors are converted and post-ready errors update state',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      native.intercept = (call) async {
        if (call.method == 'open') {
          throw PlatformException(code: 'network_failed', message: 'Offline');
        }
        return native.respond(call);
      };
      final failed = expectLater(
        controller.open(source),
        throwsA(
          isA<LumioPlayerError>().having(
            (e) => e.code,
            'code',
            'network_failed',
          ),
        ),
      );
      await tester.pump();
      await failed;
      native.intercept = null;
      await open(tester, controller);
      await native.emit({
        'id': 2,
        'type': 'error',
        'code': 'network_failed',
        'message': 'Disconnected',
      });
      await tester.pump();
      expect(controller.value.error?.code, 'network_failed');
      expect(controller.value.buffering, isFalse);
    },
  );

  test('event channel error envelopes produce a safe player error', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await open(tester, controller);
    await native.send(
      _codec.encodeErrorEnvelope(code: 'transport', message: 'Broken stream'),
    );
    await tester.pump();
    expect(controller.value.error?.code, 'event_channel');
    expect(controller.value.error?.message, 'Native event channel failed.');
  });

  test(
    'automatic chooses native and changing to the active engine is a no-op',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player(engine: LumioPlaybackEngine.automatic);
      await open(tester, controller);
      expect(controller.requestedEngine, LumioPlaybackEngine.automatic);
      expect(controller.value.engine, LumioPlaybackEngine.native);
      final changing = controller.setEngine(LumioPlaybackEngine.native);
      await tester.pump();
      await changing;
      expect(controller.requestedEngine, LumioPlaybackEngine.native);
      expect(native.named('create'), hasLength(1));
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(controller.capabilities.httpHeaders, isTrue);
      expect(controller.capabilities.formats, contains(LumioMediaFormat.rtsp));
      expect(
        () => controller.capabilities.formats.clear(),
        throwsUnsupportedError,
      );
      debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
      expect(controller.capabilities.httpHeaders, isFalse);
      expect(
        controller.capabilities.formats,
        isNot(contains(LumioMediaFormat.dash)),
      );
    },
  );

  test(
    'engine can be selected before open; incompatible web source is rejected',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      final changing = controller.setEngine(LumioPlaybackEngine.webview);
      await tester.pump();
      await changing;
      expect(native.calls, isEmpty);
      final failed = expectLater(
        controller.open(LumioSource.file('/video.mp4')),
        throwsA(
          isA<LumioPlayerError>().having(
            (e) => e.code,
            'code',
            'unsupported_web_source',
          ),
        ),
      );
      await tester.pump();
      await failed;
      expect(controller.value.engine, LumioPlaybackEngine.webview);
      expect(native.calls, isEmpty);
      expect(controller.capabilities.localFiles, isFalse);
      expect(controller.capabilities.assets, isFalse);
    },
  );

  test(
    'initialization timeout waiting for native state releases resources',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      native.initialize = false;
      final controller = player();
      final failed = expectLater(
        controller.open(source),
        throwsA(
          isA<LumioPlayerError>().having(
            (e) => e.code,
            'code',
            'initialization_timeout',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await failed;
      expect(controller.value.error?.code, 'initialization_timeout');
      expect(controller.value.transitioning, isFalse);
      expect(controller.textureId, isNull);
      expect(native.named('dispose'), hasLength(1));
      expect(native.eventCalls, ['listen', 'cancel']);
    },
  );

  test('initialization timeout also bounds native create', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final gate = Completer<Object?>();
    native.intercept = (call) =>
        call.method == 'create' ? gate.future : native.respond(call);
    final controller = player();
    var settled = false;
    final opening = controller
        .open(source)
        .then<void>(
          (_) {
            settled = true;
          },
          onError: (Object error) {
            settled = true;
            expect(
              error,
              isA<LumioPlayerError>().having(
                (e) => e.code,
                'code',
                'initialization_timeout',
              ),
            );
          },
        );
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    final settledAtDeadline = settled;
    // Unblock even when the assertion will fail; never leave teardown hanging.
    gate.complete({'id': 1, 'textureId': 101});
    await tester.pump();
    await opening;
    expect(
      settledAtDeadline,
      isTrue,
      reason:
          'open must fail at initializationTimeout even when create never responds',
    );
  });

  test(
    'logger and diagnostics redact source, headers and unrelated signed URLs',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final entries = <LumioLogEntry>[];
      final streamed = <LumioLogEntry>[];
      final controller = player(logger: entries.add);
      controller.logs.listen(streamed.add);
      final secretSource = LumioSource.network(
        Uri.parse(
          'https://user:password@example.com/video?token=source-secret',
        ),
        headers: {'Authorization': 'Bearer header-secret'},
      );
      final opening = controller.open(secretSource);
      await tester.pump();
      await opening;
      const otherUrl = 'https://other.example.com/media?token=other-secret';
      final message = '${secretSource.uri} Bearer header-secret $otherUrl';
      await native.emit({
        'id': 1,
        'type': 'error',
        'code': 'network_failed',
        'message': message,
        'details': message,
      });
      await tester.pump();
      native.intercept = (call) async {
        if (call.method == 'diagnostics') {
          return {
            'nested': [
              {'url': message},
            ],
            'count': 7,
          };
        }
        if (call.method == 'play') {
          throw PlatformException(
            code: 'play_failed',
            message: message,
            details: message,
          );
        }
        return native.respond(call);
      };
      final failed = expectLater(
        controller.play(),
        throwsA(isA<LumioPlayerError>()),
      );
      await tester.pump();
      await failed;
      final diagnostics = await controller.diagnostics();
      final safeOutput = [
        entries,
        streamed,
        controller.value.error,
        controller.value.error?.details,
        diagnostics,
      ].toString();
      for (final secret in [
        'password',
        'source-secret',
        'header-secret',
        'other-secret',
      ]) {
        expect(safeOutput, isNot(contains(secret)));
      }
      expect(safeOutput, contains('[source]'));
      expect(safeOutput, contains('[redacted]'));
      expect(safeOutput, contains('[url]'));
      expect(streamed.map((e) => e.code), entries.map((e) => e.code));
      expect((diagnostics['native'] as Map)['count'], 7);
    },
  );

  test(
    'temporary speed restore cannot overwrite a newer queued speed command',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      await open(tester, controller);
      final boost = controller.setSpeed(2);
      final revision = controller.speedRevision;
      await boost;
      final gate = Completer<void>();
      native.intercept = (call) async {
        if (call.method == 'speed' && (call.arguments as Map)['speed'] == 3) {
          await gate.future;
        }
        return native.respond(call);
      };
      final developerChange = controller.setSpeed(3);
      final restore = controller.restoreSpeedIfUnchanged(
        revision: revision,
        temporarySpeed: 2,
        originalSpeed: 1,
      );
      await tester.pump();
      gate.complete();
      await Future.wait([developerChange, restore]);
      expect(controller.value.speed, 3);
      expect(
        native.named('speed').map((call) => (call.arguments as Map)['speed']),
        [2, 3],
      );
    },
  );

  test(
    'overlapping opens are serialized until initialization completes',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      native.initialize = false;
      final first = controller.open(source);
      final nextSource = LumioSource.asset('assets/second.mp4');
      final second = controller.open(nextSource);
      await tester.pump();
      expect(native.named('create'), hasLength(1));
      expect(controller.source, same(source));
      native.initialize = true;
      await native.emit({'id': 1, 'type': 'state', 'initialized': true});
      await tester.pump();
      await Future.wait([first, second]);
      expect(native.calls.map((call) => call.method), [
        'create',
        'open',
        'dispose',
        'create',
        'open',
      ]);
      expect(controller.source, same(nextSource));
      expect(controller.textureId, 102);
    },
  );

  test('live retry does not seek to the previous position', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player();
    await open(tester, controller);
    await native.emit({
      'id': 1,
      'type': 'state',
      'live': true,
      'positionMs': 9000,
    });
    await tester.pump();
    await controller.retry();
    expect(native.named('create'), hasLength(2));
    expect(native.named('seek'), isEmpty);
  });

  test(
    'initialization timeout bounds a pending native open response',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final gate = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'open' ? gate.future : native.respond(call);
      final controller = player();
      final failed = expectLater(
        controller.open(source),
        throwsA(
          isA<LumioPlayerError>().having(
            (error) => error.code,
            'code',
            'initialization_timeout',
          ),
        ),
      );
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      await failed;
      gate.complete(null);
      expect(controller.textureId, isNull);
      expect(native.named('dispose'), hasLength(1));
      expect(controller.value.transitioning, isFalse);
    },
  );

  test(
    'command timeout uses initializationTimeout and unblocks the queue',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      const timeout = Duration(milliseconds: 100);
      final entries = <LumioLogEntry>[];
      final controller = player(
        initializationTimeout: timeout,
        logger: entries.add,
      );
      await open(tester, controller);
      final gate = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'volume' ? gate.future : native.respond(call);
      Object? failure;
      final changing = controller
          .setVolume(0.25)
          .then<void>(
            (_) {},
            onError: (Object error) {
              failure = error;
            },
          );
      final pausing = controller.pause();
      await tester.pump();
      expect(native.named('pause'), isEmpty);
      expect(failure, isNull);
      await tester.pump(timeout + const Duration(milliseconds: 20));
      final failedAtDeadline = failure;
      final pausesAtDeadline = native.named('pause').length;
      gate.complete(null);
      await Future.wait([changing, pausing]);
      expect(
        failedAtDeadline,
        isA<LumioPlayerError>()
            .having((error) => error.code, 'code', 'command_timeout')
            .having(
              (error) => error.engine,
              'engine',
              LumioPlaybackEngine.native,
            ),
      );
      expect(pausesAtDeadline, 1);
      expect(
        controller.value.volume,
        1,
        reason: 'a late successful reply must not commit timed-out settings',
      );
      expect(
        entries.where((entry) => entry.code == 'command_timeout'),
        hasLength(1),
      );
      await controller.setSpeed(1.5);
      expect(controller.value.speed, 1.5);
    },
  );

  test(
    'command errors expose sanitized LumioPlayerError to the caller',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      final secretSource = LumioSource.network(
        Uri.parse(
          'https://user:password@example.com/video?token=source-secret',
        ),
        headers: {'Authorization': 'Bearer header-secret'},
      );
      await controller.open(secretSource);
      final unsafe =
          '${secretSource.uri} Bearer header-secret '
          'https://other.example.com/video?token=other-secret';
      native.intercept = (call) async {
        if (call.method == 'play') {
          throw PlatformException(
            code: 'play_failed',
            message: unsafe,
            details: {'native': unsafe},
          );
        }
        return native.respond(call);
      };
      Object? failure;
      try {
        await controller.play();
      } catch (error) {
        failure = error;
      }
      expect(
        failure,
        isA<LumioPlayerError>()
            .having((error) => error.code, 'code', 'play_failed')
            .having(
              (error) => error.engine,
              'engine',
              LumioPlaybackEngine.native,
            ),
      );
      final error = failure as LumioPlayerError;
      final publicOutput = '${error.message} ${error.details} $error';
      for (final secret in [
        'password',
        'source-secret',
        'header-secret',
        'other-secret',
      ]) {
        expect(publicOutput, isNot(contains(secret)));
      }
      expect(publicOutput, contains('[source]'));
      expect(publicOutput, contains('[redacted]'));
      expect(publicOutput, contains('[url]'));
      await controller.pause();
    },
  );

  test(
    'retry after API pause overrides configured autoplay and stale playing state',
    () async {
      final tester = _Clock();
      addTearDown(() => finish(tester));
      final controller = player();
      expect(controller.configuration.autoPlay, isTrue);
      await open(tester, controller);
      await controller.pause();
      // Native confirmation may lag behind the successful pause command.
      expect(controller.value.playing, isTrue);
      await controller.retry();
      final config =
          (native.named('open').last.arguments as Map)['config'] as Map;
      expect(config['autoPlay'], isFalse);
      expect(controller.value.playing, isFalse);
      expect(native.named('create'), hasLength(2));
    },
  );

  test('retry during buffering preserves explicit API play intent', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player(autoPlay: false);
    await open(tester, controller);
    await controller.play();
    await native.emit({
      'id': 1,
      'type': 'state',
      'playing': false,
      'buffering': true,
      'positionMs': 2400,
    });
    await tester.pump();
    expect(controller.value.playing, isFalse);
    expect(controller.value.buffering, isTrue);
    // Switching native to automatic is a no-op here; retry forces a restart.
    await controller.retry();
    final config =
        (native.named('open').last.arguments as Map)['config'] as Map;
    expect(config['autoPlay'], isTrue);
    expect(controller.value.playing, isTrue);
    expect(native.named('create'), hasLength(2));
    expect(native.named('seek').single.arguments, {
      'id': 2,
      'positionMs': 2400,
    });
  });

  test('throwing logger cannot interrupt initialization or commands', () async {
    final tester = _Clock();
    addTearDown(() => finish(tester));
    final controller = player(logger: (_) => throw StateError('Logger failed'));
    await open(tester, controller);
    final playing = controller.play();
    await tester.pump();
    await playing;
    expect(controller.value.initialized, isTrue);
  });
}
