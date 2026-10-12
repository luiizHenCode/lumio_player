import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';
import 'package:lumio_player/src/web_engine.dart';
// The platform interface is supplied by the package's WebView dependencies.
// ignore: depend_on_referenced_packages
import 'package:webview_flutter_platform_interface/webview_flutter_platform_interface.dart';

import 'controller_test.dart' show NativeMock;

class _WebPlatform extends WebViewPlatform {
  late _WebController web;
  bool autoOpenAck = true;

  @override
  PlatformWebViewController createPlatformWebViewController(
    PlatformWebViewControllerCreationParams params,
  ) => web = (_WebController(params)..autoOpenAck = autoOpenAck);

  @override
  PlatformNavigationDelegate createPlatformNavigationDelegate(
    PlatformNavigationDelegateCreationParams params,
  ) => _NavigationDelegate(params);
}

class _NavigationDelegate extends PlatformNavigationDelegate {
  _NavigationDelegate(super.params) : super.implementation();

  @override
  Future<void> setOnNavigationRequest(
    NavigationRequestCallback callback,
  ) async {}

  @override
  Future<void> setOnWebResourceError(WebResourceErrorCallback callback) async {}
}

class _WebController extends PlatformWebViewController {
  _WebController(super.params) : super.implementation();

  late JavaScriptChannelParams channel;
  final requests = <Map<String, dynamic>>[];
  bool autoDisposeAck = true;
  bool autoOpenAck = true;

  void emit(Map<String, Object?> event) =>
      channel.onMessageReceived(JavaScriptMessage(message: jsonEncode(event)));

  void ack(Map<String, dynamic> request, {bool ok = true, Object? data}) =>
      emit({
        'type': 'ack',
        'request': request['request'],
        'ok': ok,
        'data': ?data,
        if (!ok) 'code': 'cleanup_failed',
      });

  @override
  Future<void> setJavaScriptMode(JavaScriptMode mode) async {}

  @override
  Future<void> setBackgroundColor(Color color) async {}

  @override
  Future<void> addJavaScriptChannel(JavaScriptChannelParams params) async {
    channel = params;
  }

  @override
  Future<void> setPlatformNavigationDelegate(
    PlatformNavigationDelegate delegate,
  ) async {}

  @override
  Future<void> loadFlutterAsset(String key) async => emit({'type': 'ready'});

  @override
  Future<void> runJavaScript(String script) async {
    const prefix = 'window.LumioPlayer.receive(JSON.parse(';
    final literal = script.substring(prefix.length, script.length - 3);
    final request = Map<String, dynamic>.from(
      jsonDecode(jsonDecode(literal) as String) as Map,
    );
    requests.add(request);
    if (request['method'] == 'open' && autoOpenAck) {
      emit({'type': 'state', 'initialized': true, 'buffering': false});
      ack(request);
    } else if (request['method'] == 'dispose' && autoDisposeAck) {
      ack(request);
    }
  }
}

Future<void> _flush(WidgetTester tester) async {
  for (var i = 0; i < 12; i++) {
    await tester.pump();
  }
}

List<String> _codes(List<LumioLogEntry> entries) =>
    entries.map((entry) => entry.code).toList();

void main() {
  final source = LumioSource.network(
    Uri.parse('https://example.com/video.mp4'),
  );
  late NativeMock native;
  late _WebPlatform platform;
  late WebViewPlatform? previousPlatform;

  LumioPlayerController player({
    LumioPlaybackEngine engine = LumioPlaybackEngine.native,
    LumioLogger? logger,
    bool fallback = false,
    Duration initializationTimeout = const Duration(seconds: 20),
    Duration? commandTimeout,
  }) {
    final controller = LumioPlayerController(
      configuration: LumioPlayerConfiguration(
        engine: engine,
        allowAutomaticFallback: fallback,
        initializationTimeout: initializationTimeout,
        commandTimeout: commandTimeout,
      ),
      logger: logger,
    );

    return controller;
  }

  Future<void> open(
    WidgetTester tester,
    LumioPlayerController controller,
  ) async {
    final opening = controller.open(source);
    await _flush(tester);

    await opening;
  }

  testWidgets('web slow open is independent of command deadline', (
    tester,
  ) async {
    final controller = player(
      engine: LumioPlaybackEngine.webview,
      commandTimeout: const Duration(seconds: 2),
    );
    platform.autoOpenAck = false;
    final opening = controller.open(source);
    await _flush(tester);
    await tester.pump(const Duration(seconds: 3));
    final request = platform.web.requests.singleWhere(
      (r) => r['method'] == 'open',
    );
    platform.web.emit({
      'type': 'state',
      'initialized': true,
      'buffering': false,
    });
    platform.web.ack(request);
    await _flush(tester);
    await opening;
    expect(controller.value.initialized, isTrue);
    await controller.dispose();
  });

  testWidgets('web command can outlast initialization and old fixed deadline', (
    tester,
  ) async {
    final controller = player(
      engine: LumioPlaybackEngine.webview,
      initializationTimeout: const Duration(seconds: 1),
      commandTimeout: const Duration(seconds: 25),
    );
    await open(tester, controller);
    final playing = controller.play();
    await _flush(tester);
    await tester.pump(const Duration(seconds: 11));
    final request = platform.web.requests.last;
    expect(request['method'], 'play');
    platform.web.ack(request);
    await _flush(tester);
    await playing;
    await controller.dispose();
  });

  testWidgets('web omitted command timeout follows initialization timeout', (
    tester,
  ) async {
    final controller = player(
      engine: LumioPlaybackEngine.webview,
      initializationTimeout: const Duration(seconds: 1),
    );
    await open(tester, controller);
    final failed = expectLater(
      controller.play(),
      throwsA(
        isA<LumioPlayerError>().having(
          (error) => error.code,
          'code',
          'command_timeout',
        ),
      ),
    );
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    await failed;
    await controller.dispose();
  });

  for (final method in ['play', 'seek', 'getPosition']) {
    testWidgets('web $method uses configured command deadline', (tester) async {
      final controller = player(
        engine: LumioPlaybackEngine.webview,
        commandTimeout: const Duration(seconds: 2),
      );
      await open(tester, controller);
      final Future<Object?> action = switch (method) {
        'play' => controller.play(),
        'seek' => controller.seekTo(const Duration(seconds: 3)),
        _ => controller.getPosition(),
      };
      final failed = expectLater(
        action,
        method == 'getPosition'
            ? throwsA(isA<TimeoutException>())
            : throwsA(
                isA<LumioPlayerError>().having(
                  (error) => error.code,
                  'code',
                  'command_timeout',
                ),
              ),
      );
      await _flush(tester);
      await tester.pump(const Duration(seconds: 2));
      await _flush(tester);
      await failed;
      expect(
        platform.web.requests.where((r) => r['method'] == method),
        hasLength(1),
      );
      expect(
        (await controller.diagnostics())['native'],
        containsPair('pendingRequests', 0),
      );
      await controller.dispose();
    });
  }

  testWidgets('initialization timeout still permits automatic fallback', (
    tester,
  ) async {
    native.initialize = false;
    final controller = player(
      engine: LumioPlaybackEngine.automatic,
      fallback: true,
      initializationTimeout: const Duration(seconds: 1),
      commandTimeout: const Duration(milliseconds: 100),
    );
    final opening = controller.open(source);
    await _flush(tester);
    await tester.pump(const Duration(seconds: 1));
    await _flush(tester);
    await opening;
    expect(controller.value.engine, LumioPlaybackEngine.webview);
    expect(controller.value.initialized, isTrue);
    expect((await controller.diagnostics())['fallbackUsed'], isTrue);
    await controller.dispose();
  });

  setUp(() {
    native = NativeMock()..install();
    previousPlatform = WebViewPlatform.instance;
    platform = _WebPlatform();
    WebViewPlatform.instance = platform;
  });

  tearDown(() {
    native.uninstall();
    WebViewPlatform.instance = previousPlatform ?? _WebPlatform();
  });

  testWidgets(
    'delayed JS ACK gates release and disposed; dispose is idempotent',
    (tester) async {
      final logged = <LumioLogEntry>[];
      final streamed = <LumioLogEntry>[];
      final controller = player(
        engine: LumioPlaybackEngine.webview,
        logger: logged.add,
      );
      var streamClosed = false;
      controller.logs.listen(streamed.add, onDone: () => streamClosed = true);
      await open(tester, controller);
      logged.clear();
      streamed.clear();
      platform.web.autoDisposeAck = false;
      var completed = false;
      final closing = controller.dispose();
      expect(controller.dispose(), same(closing));
      unawaited(closing.then((_) => completed = true));
      await _flush(tester);
      final request = platform.web.requests.last;
      expect(request['method'], 'dispose');
      await tester.pump(const Duration(milliseconds: 1999));
      expect(completed, isFalse);
      expect(streamClosed, isFalse);
      expect(_codes(logged), ['dispose_started', 'resources_release_started']);
      platform.web.ack(request);

      await _flush(tester);

      await closing;
      expect(_codes(logged), [
        'dispose_started',
        'resources_release_started',
        'resources_released',
        'disposed',
      ]);
      expect(_codes(streamed), _codes(logged));
      expect(streamClosed, isTrue);
      expect(
        logged.every((entry) => entry.playerId == controller.playerId),
        isTrue,
      );
      expect(
        platform.web.requests.where((r) => r['method'] == 'dispose'),
        hasLength(1),
      );
      await expectLater(controller.play(), throwsStateError);
      await controller.dispose();
      expect(_codes(logged).where((code) => code == 'disposed'), hasLength(1));
    },
  );

  for (final failure in ['negative ACK', 'ACK timeout']) {
    testWidgets('WebView $failure reports incomplete, never disposed', (
      tester,
    ) async {
      final entries = <LumioLogEntry>[];
      final controller = player(
        engine: LumioPlaybackEngine.webview,
        logger: entries.add,
      );
      await open(tester, controller);
      entries.clear();
      platform.web.autoDisposeAck = false;
      final closing = controller.dispose();
      await _flush(tester);
      final request = platform.web.requests.last;
      if (failure == 'negative ACK') {
        platform.web.ack(request, ok: false);
      } else {
        await tester.pump(const Duration(seconds: 2));
      }
      await _flush(tester);
      await closing;
      expect(_codes(entries), [
        'dispose_started',
        'resources_release_started',
        'dispose_failed',
        'dispose_incomplete',
      ]);
      expect(entries.last.level, LumioLogLevel.warning);
      if (failure == 'ACK timeout') {
        expect(entries[2].message, contains('timeout'));
      }
      platform.web.ack(request);
      await _flush(tester);
      expect(_codes(entries), isNot(contains('disposed')));
      expect(_codes(entries), isNot(contains('resources_released')));
    });
  }

  for (final failure in ['error', 'timeout']) {
    testWidgets(
      'native release $failure is bounded and never confirms disposed',
      (tester) async {
        final entries = <LumioLogEntry>[];
        final controller = player(logger: entries.add);
        await open(tester, controller);
        entries.clear();
        final release = Completer<Object?>();
        native.intercept = (call) =>
            call.method == 'dispose' ? release.future : native.respond(call);
        var completed = false;
        final closing = controller.dispose();
        unawaited(closing.then((_) => completed = true));
        await _flush(tester);
        expect(native.eventCalls, ['listen', 'cancel']);
        expect(native.named('dispose'), hasLength(1));
        if (failure == 'error') {
          release.completeError(PlatformException(code: 'release_failed'));
        } else {
          await tester.pump(const Duration(milliseconds: 4999));
          expect(completed, isFalse);
          await tester.pump(const Duration(milliseconds: 1));
        }
        await _flush(tester);
        await closing;
        expect(_codes(entries), [
          'dispose_started',
          'resources_release_started',
          'resources_released',
          'resources_release_started',
          'dispose_failed',
          'dispose_incomplete',
        ]);
        if (failure == 'timeout') {
          expect(entries[4].message, contains('timeout'));
          release.complete(null);
          await _flush(tester);
          expect(_codes(entries), isNot(contains('disposed')));
        }
      },
    );
  }

  testWidgets(
    'pending event channel cancellation reply does not block native cleanup',
    (tester) async {
      final entries = <LumioLogEntry>[];
      final controller = player(logger: entries.add);
      await open(tester, controller);
      entries.clear();
      final cancellation = Completer<Object?>();
      native.messenger.setMockMethodCallHandler(
        const MethodChannel('lumio_player/events'),
        (call) =>
            call.method == 'cancel' ? cancellation.future : Future.value(null),
      );
      final closing = controller.dispose();
      await _flush(tester);
      await closing;
      expect(cancellation.isCompleted, isFalse);
      expect(native.named('dispose'), hasLength(1));
      expect(_codes(entries), [
        'dispose_started',
        'resources_release_started',
        'resources_released',
        'resources_release_started',
        'resources_released',
        'disposed',
      ]);
      cancellation.complete(null);
      await _flush(tester);
    },
  );

  for (final failRelease in [false, true]) {
    testWidgets(
      'late creation closes stream before ${failRelease ? 'failed' : 'confirmed'} release',
      (tester) async {
        final entries = <LumioLogEntry>[];
        final streamed = <LumioLogEntry>[];
        final controller = player(logger: entries.add);
        var streamClosed = false;
        controller.logs.listen(streamed.add, onDone: () => streamClosed = true);
        final creation = Completer<Object?>();
        final release = Completer<Object?>();
        native.intercept = (call) {
          if (call.method == 'create') return creation.future;
          if (call.method == 'dispose') return release.future;
          return native.respond(call);
        };
        final opening = expectLater(controller.open(source), throwsStateError);
        await _flush(tester);
        final closing = controller.dispose();
        await _flush(tester);
        await closing;
        await opening;
        expect(streamClosed, isTrue);
        expect(_codes(entries), contains('dispose_pending'));
        expect(_codes(entries), isNot(contains('disposed')));
        final streamCodes = _codes(streamed);
        creation.complete({'id': 42, 'textureId': 142});
        await _flush(tester);
        expect(native.named('open'), isEmpty);
        expect(native.named('dispose').single.arguments, {'id': 42});
        expect(_codes(entries), isNot(contains('disposed')));
        if (failRelease) {
          release.completeError(PlatformException(code: 'late_release_failed'));
        } else {
          release.complete(null);
        }
        await _flush(tester);
        expect(_codes(streamed), streamCodes);
        expect(
          _codes(entries).last,
          failRelease ? 'dispose_incomplete' : 'disposed',
        );
        expect(
          _codes(entries).where((code) => code == 'disposed'),
          hasLength(failRelease ? 0 : 1),
        );
        expect(
          entries.every((entry) => entry.playerId == controller.playerId),
          isTrue,
        );
        await controller.dispose();
        expect(native.named('dispose'), hasLength(1));
      },
    );
  }

  testWidgets(
    'reentrant logger dispose shares the same future and tears down once',
    (tester) async {
      final entries = <LumioLogEntry>[];
      late LumioPlayerController controller;
      Future<void>? reentrantDisposal;
      var disposeStarted = 0;
      controller = player(
        logger: (entry) {
          entries.add(entry);
          if (entry.code == 'dispose_started') {
            disposeStarted++;
            // Bound recursion on regression, so duplicate disposal fails assertions.
            if (disposeStarted == 1) {
              reentrantDisposal = controller.dispose();
            }
          }
        },
      );
      var streamClosures = 0;
      controller.logs.listen((_) {}, onDone: () => streamClosures++);
      await open(tester, controller);
      entries.clear();
      final release = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'dispose' ? release.future : native.respond(call);

      final closing = controller.dispose();
      expect(reentrantDisposal, same(closing));
      expect(controller.dispose(), same(closing));
      var completed = false;
      unawaited(closing.then((_) => completed = true));
      await _flush(tester);
      expect(disposeStarted, 1);
      expect(native.eventCalls, ['listen', 'cancel']);
      expect(native.named('dispose').single.arguments, {'id': 1});
      expect(completed, isFalse);
      expect(streamClosures, 0);
      expect(_codes(entries), isNot(contains('disposed')));

      release.complete(null);
      await _flush(tester);
      await closing;
      await reentrantDisposal;
      expect(completed, isTrue);
      expect(streamClosures, 1);
      expect(_codes(entries), [
        'dispose_started',
        'resources_release_started',
        'resources_released',
        'resources_release_started',
        'resources_released',
        'disposed',
      ]);
      expect(controller.dispose(), same(closing));
      await controller.dispose();
      expect(native.named('dispose'), hasLength(1));
      expect(native.eventCalls, ['listen', 'cancel']);
      expect(disposeStarted, 1);
      expect(streamClosures, 1);
    },
  );

  testWidgets(
    'throwing logger cannot interrupt cleanup or stream confirmation',
    (tester) async {
      final logged = <LumioLogEntry>[];
      final streamed = <LumioLogEntry>[];
      final controller = player(
        logger: (entry) {
          logged.add(entry);
          throw StateError('logger failed');
        },
      );
      var closed = false;
      controller.logs.listen(streamed.add, onDone: () => closed = true);
      await open(tester, controller);
      final closing = controller.dispose();
      await _flush(tester);
      await closing;
      expect(closed, isTrue);
      expect(_codes(logged).last, 'disposed');
      expect(_codes(streamed), _codes(logged));
      expect(native.named('dispose'), hasLength(1));
      expect(_codes(logged), isNot(contains('dispose_failed')));
    },
  );

  testWidgets(
    'late native command cannot mutate state or dispatch queued commands',
    (tester) async {
      final entries = <LumioLogEntry>[];
      final controller = player(logger: entries.add);
      await open(tester, controller);
      final reply = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'volume' ? reply.future : native.respond(call);
      final changing = expectLater(
        controller.setVolume(0.25),
        throwsStateError,
      );
      final queued = expectLater(controller.pause(), throwsStateError);
      await _flush(tester);
      final before = controller.value;
      final closing = controller.dispose();
      await _flush(tester);
      expect(_codes(entries), isNot(contains('disposed')));
      await native.emit({'id': 1, 'type': 'state', 'volume': 0.25});
      reply.complete(null);
      await _flush(tester);
      await Future.wait([changing, queued, closing]);
      expect(controller.value, same(before));
      expect(native.named('pause'), isEmpty);
      expect(_codes(entries).last, 'disposed');
      expect(_codes(entries), isNot(contains('dispose_failed')));
    },
  );

  testWidgets('WebView position uses ACK data rather than cached events', (
    tester,
  ) async {
    final controller = player(engine: LumioPlaybackEngine.webview);
    await open(tester, controller);
    platform.web.emit({'type': 'state', 'positionMs': 1000, 'playing': false});
    final position = controller.getPosition();
    await _flush(tester);
    final request = platform.web.requests.last;
    expect(request['method'], 'getPosition');
    // A newer periodic event still isn't the answer to this request.
    platform.web.emit({'type': 'state', 'positionMs': 2000});
    platform.web.ack(request, data: 4567);
    await _flush(tester);
    expect(await position, const Duration(milliseconds: 4567));
    expect(controller.value.position, const Duration(milliseconds: 4567));
    expect(controller.capabilities.supportsSurfaceCapture, isFalse);
    expect(controller.capabilities.nativePlatformView, isFalse);
    final closing = controller.dispose();
    await _flush(tester);
    await closing;
    await expectLater(controller.getPosition(), throwsStateError);
  });

  testWidgets('source replacement rejects late WebView position data', (
    tester,
  ) async {
    final controller = player(engine: LumioPlaybackEngine.webview);
    await open(tester, controller);
    final position = expectLater(controller.getPosition(), throwsStateError);
    await _flush(tester);
    final oldWeb = platform.web;
    final request = oldWeb.requests.last;
    final reopening = controller.open(source);
    oldWeb.ack(request, data: 9876);
    await _flush(tester);
    await position;
    await reopening;
    expect(controller.value.position, Duration.zero);
    final closing = controller.dispose();
    await _flush(tester);
    await closing;
  });

  testWidgets(
    'fallback rejects pending native position and clears old buffers',
    (tester) async {
      final controller = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(autoPlay: false),
      );
      await open(tester, controller);
      controller.value = controller.value.apply({
        'bufferedPositionMs': 9000,
        'bufferedRanges': [
          {'startMs': 0, 'endMs': 9000},
        ],
      });
      final reply = Completer<Object?>();
      native.intercept = (call) =>
          call.method == 'getPosition' ? reply.future : native.respond(call);
      final position = expectLater(controller.getPosition(), throwsStateError);
      await _flush(tester);
      await native.emit({
        'id': controller.nativePlayerId,
        'type': 'error',
        'code': 'decoder_failed',
      });
      await _flush(tester);
      reply.complete(9876);
      // Failure snapshots are deliberately scheduled on the next timer turn.
      await tester.pump(const Duration(milliseconds: 1));
      await _flush(tester);
      await position;
      expect(controller.value.engine, LumioPlaybackEngine.webview);
      expect(controller.value.position, Duration.zero);
      expect(controller.value.buffered, isEmpty);
      expect(controller.value.bufferedPosition, Duration.zero);
      expect(controller.nativePlayerId, isNull);
      expect(controller.capabilities.supportsSurfaceCapture, isFalse);
      final closing = controller.dispose();
      await _flush(tester);
      await closing;
    },
  );

  testWidgets('dispose rejects late WebView position data', (tester) async {
    final controller = player(engine: LumioPlaybackEngine.webview);
    await open(tester, controller);
    final position = expectLater(controller.getPosition(), throwsStateError);
    await _flush(tester);
    final request = platform.web.requests.last;
    final closing = controller.dispose();
    platform.web.ack(request, data: 9876);
    await _flush(tester);
    await position;
    await closing;
    expect(controller.value.position, Duration.zero);
  });

  testWidgets(
    'WebView dispose cancels pending command and ignores its late ACK',
    (tester) async {
      final events = <Map<String, dynamic>>[];
      final engine = LumioWebEngine(onEvent: events.add);
      await _flush(tester);
      final pending = expectLater(engine.command('play'), throwsStateError);
      await _flush(tester);
      final command = platform.web.requests.last;
      platform.web.autoDisposeAck = false;
      final closing = engine.dispose();
      expect(engine.dispose(), same(closing));
      await _flush(tester);
      await pending;
      final disposal = platform.web.requests.last;
      platform.web.ack(command);
      platform.web.emit({'type': 'state', 'initialized': true});
      expect(events, isEmpty);
      expect(engine.diagnostics['pendingRequests'], 1);
      platform.web.ack(disposal);
      await _flush(tester);
      await closing;
      expect(engine.diagnostics['pendingRequests'], 0);
      await expectLater(engine.command('pause'), throwsStateError);
    },
  );
}
