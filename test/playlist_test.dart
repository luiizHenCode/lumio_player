import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

const _methods = MethodChannel('lumio_player/methods');
const _events = MethodChannel('lumio_player/events');
const _codec = StandardMethodCodec();

/// Shared by headers_test.dart; models native commands, not a WebView engine.
class NativePlaylistFake {
  final messenger =
      TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
  final calls = <MethodCall>[];
  final eventCalls = <String>[];
  int nextId = 1;
  int id = 0;
  int index = 0;
  int length = 0;
  bool playing = false;
  bool initializeOpen = true;
  bool initializeSelection = true;
  bool selectionPauses = true;
  Completer<void>? selectionReply;
  Object? diagnosticsResult;

  void install() {
    messenger.setMockMethodCallHandler(_events, (call) async {
      eventCalls.add(call.method);
      return null;
    });
    messenger.setMockMethodCallHandler(_methods, (call) async {
      calls.add(call);
      if (call.method == 'create') {
        id = nextId++;
        return {'id': id, 'textureId': id + 100};
      }
      final args = Map<String, dynamic>.from(call.arguments as Map);
      switch (call.method) {
        case 'open':
        case 'openPlaylist':
          id = args['id'] as int;
          index = args['index'] as int? ?? 0;
          length = call.method == 'openPlaylist'
              ? (args['sources'] as List).length
              : 1;
          playing = (args['config'] as Map)['autoPlay'] as bool;
          if (initializeOpen) await state();
        case 'selectPlaylistItem':
          index = args['index'] as int;
          if (selectionPauses) playing = false;
          if (initializeSelection) await state();
          await selectionReply?.future;
        case 'play':
          playing = true;
          await state(initialized: initializeSelection);
        case 'pause':
          playing = false;
          await state();
        case 'diagnostics':
          return diagnosticsResult ?? <String, Object?>{};
      }
      return null;
    });
  }

  Future<void> state({
    bool initialized = true,
    Map<String, Object?> extra = const {},
  }) => emit({
    'id': id,
    'type': 'state',
    'initialized': initialized,
    'playing': playing,
    'buffering': !initialized,
    'completed': false,
    'positionMs': 0,
    'durationMs': 10000,
    'playlistIndex': index,
    'playlistLength': length,
    ...extra,
  });

  Future<void> emit(Map<String, Object?> event) {
    unawaited(
      messenger.handlePlatformMessage(
        _events.name,
        _codec.encodeSuccessEnvelope(event),
        null,
      ),
    );
    return SynchronousFuture<void>(null);
  }

  List<MethodCall> named(String name) =>
      calls.where((call) => call.method == name).toList();

  void uninstall() {
    messenger.setMockMethodCallHandler(_methods, null);
    messenger.setMockMethodCallHandler(_events, null);
  }
}

Future<void> flushNativeEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}

LumioPlaylist samplePlaylist({bool loop = false, bool headers = false}) =>
    LumioPlaylist([
      for (var i = 0; i < 3; i++)
        LumioPlaylistItem(
          source: LumioSource.network(
            Uri.parse('https://example.com/item-$i.mp4'),
            headers: headers ? {'Authorization': 'item-secret-$i'} : const {},
          ),
          title: 'Item $i',
        ),
    ], loop: loop);

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativePlaylistFake native;
  late List<LumioPlayerController> players;

  LumioPlayerController player({
    bool autoPlay = true,
    bool looping = false,
    Duration timeout = const Duration(seconds: 1),
  }) {
    final controller = LumioPlayerController(
      configuration: LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: autoPlay,
        looping: looping,
        allowAutomaticFallback: false,
        initializationTimeout: timeout,
      ),
    );
    players.add(controller);
    return controller;
  }

  setUp(() {
    native = NativePlaylistFake()..install();
    players = [];
  });
  tearDown(() async {
    if (native.selectionReply != null && !native.selectionReply!.isCompleted) {
      native.selectionReply!.complete();
    }
    for (final controller in players) {
      await controller.dispose();
    }
    native.uninstall();
    debugDefaultTargetPlatformOverride = null;
  });

  test('playlist and item models defensively copy immutable collections', () {
    expect(() => LumioPlaylist([]), throwsArgumentError);
    final headers = {'Authorization': 'original'};
    final source = LumioSource.network(
      Uri.parse('https://example.com/video'),
      headers: headers,
    );
    final item = LumioPlaylistItem(source: source, title: 'First');
    final items = [item];
    final playlist = LumioPlaylist(items, loop: true);
    headers['Authorization'] = 'changed';
    items.clear();
    expect(playlist.items, [same(item)]);
    expect(playlist.items.single.source, same(source));
    expect(playlist.items.single.title, 'First');
    expect(playlist.loop, isTrue);
    expect(source.headers, {'Authorization': 'original'});
    expect(() => playlist.items.clear(), throwsUnsupportedError);
    expect(() => playlist.items[0] = item, throwsUnsupportedError);
    expect(() => source.headers.clear(), throwsUnsupportedError);
  });

  for (final loop in [false, true]) {
    test(
      'openPlaylist serializes sources, initial index and loop=$loop',
      () async {
        final controller = player(looping: true, autoPlay: false);
        final playlist = samplePlaylist(loop: loop);
        await controller.openPlaylist(playlist, initialIndex: 1);
        expect(native.calls.map((c) => c.method), ['create', 'openPlaylist']);
        expect(native.eventCalls, ['listen']);
        expect(native.named('openPlaylist').single.arguments, {
          'id': 1,
          'sources': playlist.items.map((item) => item.source.toMap()).toList(),
          'index': 1,
          'config': {...controller.configuration.toMap(), 'loopPlaylist': loop},
        });
        expect(controller.playlist!.loop, loop);
        expect(controller.playlistIndex, 1);
        expect(controller.currentItem, same(controller.playlist!.items[1]));
        expect(controller.source, same(playlist.items[1].source));
        expect(controller.title, 'Item 1');
        expect(controller.value.playlistIndex, 1);
        expect(controller.value.playlistLength, 3);
        expect(controller.value.initialized, isTrue);
        expect(controller.value.playing, isFalse);
        expect(controller.value.transitioning, isFalse);
        expect(controller.textureId, 101);
        expect(controller.capabilities.nativePlaylist, isTrue);
      },
    );
  }

  test(
    'native auto-advance updates item, source, title and state without commands',
    () async {
      final controller = player();
      await controller.openPlaylist(samplePlaylist());
      final texture = controller.textureId;
      final callCount = native.calls.length;
      await native.emit({
        'id': native.id,
        'type': 'error',
        'playlistIndex': 0,
        'code': 'old_item_error',
        'message': 'Old item failed',
      });
      await flushNativeEvents();
      expect(controller.value.error?.code, 'old_item_error');
      final failure = (await controller.failureReport())!;
      expect((failure.metadata['playback'] as Map)['playlistIndex'], 0);
      native.index = 1;
      await native.state(
        extra: {
          'positionMs': 250,
          'durationMs': 8000,
          'bufferedPositionMs': 2000,
          'width': 640,
          'height': 480,
        },
      );
      await flushNativeEvents();
      expect(controller.playlistIndex, 1);
      expect(controller.currentItem, same(controller.playlist!.items[1]));
      expect(controller.source, same(controller.currentItem!.source));
      expect(controller.title, 'Item 1');
      expect(controller.value.playlistIndex, 1);
      expect(controller.value.playlistLength, 3);
      expect(controller.value.position, const Duration(milliseconds: 250));
      expect(controller.value.duration, const Duration(seconds: 8));
      expect(controller.value.bufferedPosition, const Duration(seconds: 2));
      expect(controller.value.aspectRatio, 4 / 3);
      expect(controller.value.playing, isTrue);
      expect(controller.value.error, isNull);
      expect(controller.textureId, texture);
      expect(
        native.calls.where((call) => call.method != 'diagnostics').length,
        callCount,
      );
      expect(native.named('diagnostics'), hasLength(1));
      expect((await controller.failureReport())!.timestamp, failure.timestamp);
    },
  );

  for (final platform in [TargetPlatform.iOS, TargetPlatform.android]) {
    for (final intendedPlaying in [false, true]) {
      test(
        '$platform select/next/previous retain intent=$intendedPlaying and texture',
        () async {
          debugDefaultTargetPlatformOverride = platform;
          native.selectionPauses = platform == TargetPlatform.iOS;
          // Deliberately invert autoPlay to test explicit user intent, not config.
          final controller = player(autoPlay: !intendedPlaying);
          await controller.openPlaylist(samplePlaylist());
          if (intendedPlaying) {
            await controller.play();
          } else {
            await controller.pause();
          }
          // Actual playing=false while buffering must not erase play intent.
          if (intendedPlaying) {
            await native.state(extra: {'playing': false, 'buffering': true});
            await flushNativeEvents();
          }
          final texture = controller.textureId;
          final before = native.calls.length;
          await controller.selectPlaylistItem(1);
          await controller.next();
          await controller.previous();
          await flushNativeEvents();
          final selectionCalls = native.calls.skip(before).toList();
          expect(selectionCalls.map((c) => c.method), [
            'selectPlaylistItem',
            if (intendedPlaying) 'play',
            'selectPlaylistItem',
            if (intendedPlaying) 'play',
            'selectPlaylistItem',
            if (intendedPlaying) 'play',
          ]);
          expect(native.named('selectPlaylistItem').map((c) => c.arguments), [
            {'id': 1, 'index': 1, 'selectionEpoch': 1},
            {'id': 1, 'index': 2, 'selectionEpoch': 2},
            {'id': 1, 'index': 1, 'selectionEpoch': 3},
          ]);
          expect(controller.value.playing, intendedPlaying);
          expect(controller.value.initialized, isTrue);
          expect(controller.value.transitioning, isFalse);
          expect(controller.value.completed, isFalse);
          expect(controller.value.position, Duration.zero);
          expect(controller.playlistIndex, 1);
          expect(controller.title, 'Item 1');
          expect(controller.textureId, texture);
          expect(native.named('create'), hasLength(1));
          expect(native.named('openPlaylist'), hasLength(1));
          expect(native.named('dispose'), isEmpty);
        },
      );
    }
  }

  test(
    'nonlooping queue boundaries are no-ops and final completion stays put',
    () async {
      final controller = player();
      await controller.openPlaylist(samplePlaylist());
      expect(controller.hasPrevious, isFalse);
      expect(controller.hasNext, isTrue);
      final before = native.calls.length;
      await controller.previous();
      expect(native.calls.length, before);
      await controller.selectPlaylistItem(2);
      expect(controller.hasNext, isFalse);
      expect(controller.hasPrevious, isTrue);
      await native.state(extra: {'playing': false, 'completed': true});
      await flushNativeEvents();
      final atEnd = native.calls.length;
      await controller.next();
      expect(native.calls.length, atEnd);
      expect(controller.playlistIndex, 2);
      expect(controller.value.completed, isTrue);
    },
  );

  test(
    'looping queue wraps both directions; native wrap issues no parent command',
    () async {
      final controller = player();
      await controller.openPlaylist(samplePlaylist(loop: true));
      expect(controller.hasNext, isTrue);
      expect(controller.hasPrevious, isTrue);
      await controller.previous();
      expect(controller.playlistIndex, 2);
      await controller.next();
      expect(controller.playlistIndex, 0);
      await controller.selectPlaylistItem(2);
      final before = native.calls.length;
      native.index = 0;
      await native.state();
      await flushNativeEvents();
      expect(controller.playlistIndex, 0);
      expect(controller.title, 'Item 0');
      expect(controller.value.completed, isFalse);
      expect(native.calls.length, before);
    },
  );

  test('one-item queues have no next/previous even when looping', () async {
    final controller = player();
    await controller.openPlaylist(
      LumioPlaylist([samplePlaylist().items.first], loop: true),
    );
    final before = native.calls.length;
    expect(controller.hasNext, isFalse);
    expect(controller.hasPrevious, isFalse);
    await controller.next();
    await controller.previous();
    expect(native.calls.length, before);
  });

  test(
    'invalid indexes leave the existing playlist and native queue untouched',
    () async {
      final controller = player();
      await expectLater(controller.selectPlaylistItem(0), throwsStateError);
      await controller.next();
      await controller.previous();
      expect(native.calls, isEmpty);
      await controller.openPlaylist(samplePlaylist(), initialIndex: 1);
      final playlist = controller.playlist;
      final before = native.calls.length;
      for (final index in [-1, 3]) {
        await expectLater(
          controller.selectPlaylistItem(index),
          throwsRangeError,
        );
        await expectLater(
          controller.openPlaylist(samplePlaylist(), initialIndex: index),
          throwsRangeError,
        );
      }
      expect(controller.playlist, same(playlist));
      expect(controller.playlistIndex, 1);
      expect(native.calls.length, before);
    },
  );

  test('switch back to native retains index, queue and paused intent', () async {
    final controller = player();
    await controller.openPlaylist(samplePlaylist(loop: true, headers: true));
    await controller.selectPlaylistItem(2);
    await controller.pause();
    await native.state(extra: {'positionMs': 1200});
    await flushNativeEvents();
    // Headers reject WebView before its platform controller is constructed.
    await expectLater(
      controller.setEngine(LumioPlaybackEngine.webview),
      throwsA(
        isA<LumioPlayerError>().having(
          (e) => e.code,
          'code',
          'unsupported_web_source',
        ),
      ),
    );
    expect(controller.capabilities.nativePlaylist, isFalse);
    expect(controller.playlistIndex, 2);
    await controller.setEngine(LumioPlaybackEngine.native);
    expect(controller.capabilities.nativePlaylist, isTrue);
    expect(controller.playlistIndex, 2);
    expect(controller.title, 'Item 2');
    expect(controller.value.playing, isFalse);
    final reopened = native.named('openPlaylist').last.arguments as Map;
    expect(reopened['index'], 2);
    expect(reopened['sources'], hasLength(3));
    expect((reopened['config'] as Map)['loopPlaylist'], isTrue);
    expect((reopened['config'] as Map)['autoPlay'], isFalse);
    // The failed WebView start resets its state position to zero; this test
    // deliberately asserts index persistence, not successful WebView playback.
    expect(native.named('create'), hasLength(2));
    expect(controller.textureId, 102);
  });

  test(
    'stale indexed errors are ignored, including while selection awaits readiness',
    () async {
      final controller = player(autoPlay: false);
      await controller.openPlaylist(samplePlaylist());
      native.initializeSelection = false;
      final selecting = controller.selectPlaylistItem(1);
      await flushNativeEvents();
      await native.emit({
        'id': native.id,
        'type': 'error',
        'playlistIndex': 0,
        'code': 'stale_error',
        'message': 'Previous item failed',
      });
      await flushNativeEvents();
      expect(controller.value.error, isNull);
      expect(controller.value.transitioning, isTrue);
      await native.state();
      await selecting;
      await native.emit({
        'id': native.id,
        'type': 'error',
        'playlistIndex': 2,
        'code': 'future_item_error',
        'message': 'Other item failed',
      });
      await flushNativeEvents();
      expect(controller.value.error, isNull);
      expect(controller.playlistIndex, 1);
      await native.emit({
        'id': native.id,
        'type': 'error',
        'playlistIndex': 1,
        'code': 'current_error',
        'message': 'Current item failed',
      });
      await flushNativeEvents();
      expect(controller.value.error?.code, 'current_error');
    },
  );

  test('dispose cancels selection waiting for an initialized event', () async {
    final controller = player(autoPlay: false);
    await controller.openPlaylist(samplePlaylist());
    native.initializeSelection = false;
    final selecting = controller.selectPlaylistItem(1);
    final rejected = expectLater(selecting, throwsStateError);
    await flushNativeEvents();
    expect(controller.value.transitioning, isTrue);
    await controller.dispose().timeout(const Duration(milliseconds: 200));
    await rejected;
    expect(controller.textureId, isNull);
    expect(native.named('dispose').single.arguments, {'id': 1});
    await expectLater(controller.next(), throwsStateError);
  });

  test(
    'dispose promptly cancels selection with an outstanding native reply',
    () async {
      final controller = player(autoPlay: false);
      await controller.openPlaylist(samplePlaylist());
      native.initializeSelection = false;
      native.selectionReply = Completer<void>();
      final selecting = controller.selectPlaylistItem(1);
      final rejected = expectLater(selecting, throwsStateError);
      await flushNativeEvents();
      final closing = controller.dispose();
      try {
        await closing.timeout(const Duration(milliseconds: 200));
      } finally {
        native.selectionReply!.complete();
        await closing;
        await rejected;
      }
    },
  );

  test(
    'selection readiness timeout records error and retry reopens at selected index',
    () async {
      final controller = player(
        autoPlay: false,
        timeout: const Duration(milliseconds: 80),
      );
      await controller.openPlaylist(samplePlaylist(loop: true));
      native.initializeSelection = false;
      await expectLater(
        controller.selectPlaylistItem(2),
        throwsA(
          isA<LumioPlayerError>().having(
            (e) => e.code,
            'code',
            'initialization_timeout',
          ),
        ),
      );
      expect(controller.value.error?.code, 'initialization_timeout');
      expect(controller.value.transitioning, isFalse);
      expect(controller.value.buffering, isFalse);
      expect(controller.playlistIndex, 2);
      expect(controller.source, same(controller.playlist!.items[2].source));
      expect(controller.title, 'Item 2');
      await controller.retry();
      expect(native.named('create'), hasLength(2));
      expect(native.named('dispose'), hasLength(1));
      final reopened = native.named('openPlaylist').last.arguments as Map;
      expect(reopened['index'], 2);
      expect((reopened['config'] as Map)['autoPlay'], isFalse);
      expect((reopened['config'] as Map)['loopPlaylist'], isTrue);
      expect(controller.value.initialized, isTrue);
      expect(controller.value.error, isNull);
      expect(controller.value.playlistLength, 3);
    },
  );

  test(
    'ordinary open clears playlist, index, item and queue navigation',
    () async {
      final controller = player();
      await controller.openPlaylist(samplePlaylist(), initialIndex: 2);
      await controller.openUrl(
        'https://example.com/standalone.mp4',
        title: 'Single',
      );
      expect(controller.playlist, isNull);
      expect(controller.currentItem, isNull);
      expect(controller.playlistIndex, 0);
      expect(controller.title, 'Single');
      expect(controller.hasNext, isFalse);
      expect(controller.hasPrevious, isFalse);
      expect(controller.value.playlistIndex, 0);
      expect(controller.value.playlistLength, 1);
      expect(
        (native.named('open').single.arguments
            as Map)['config']['loopPlaylist'],
        isNull, // Ordinary open uses the native default (false).
      );
    },
  );
}
