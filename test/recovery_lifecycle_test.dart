import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/widgets.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;
import 'playlist_test.dart' show NativePlaylistFake, samplePlaylist;
import 'recovery_test.dart' show flush, recovery;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeMock native;
  late LumioPlayerController player;
  final source = LumioSource.network(Uri.parse('https://example.com/live'));

  void create({bool background = false}) {
    player = LumioPlayerController(
      recovery: recovery,
      configuration: LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        mode: LumioPlaybackMode.live,
        allowBackgroundPlayback: background,
        allowAutomaticFallback: false,
      ),
    );
  }

  setUp(() {
    native = NativeMock()..install();
    create();
  });
  tearDown(() async {
    await player.dispose();
    debugDefaultTargetPlatformOverride = null;
    native.uninstall();
  });

  for (final state in [
    AppLifecycleState.hidden,
    AppLifecycleState.paused,
    AppLifecycleState.detached,
  ]) {
    test('$state pauses and resumed restores valid play intent', () async {
      await player.open(source);
      player.didChangeAppLifecycleState(state);
      await flush();
      expect(native.named('pause'), hasLength(1));
      await flush(180);
      expect(native.named('open'), hasLength(1));
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await flush();
      expect(native.named('play'), hasLength(1));
    });
  }

  test('inactive does not pause or resume playback', () async {
    await player.open(source);
    player.didChangeAppLifecycleState(AppLifecycleState.inactive);
    player.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(native.named('pause'), isEmpty);
    expect(native.named('play'), isEmpty);
  });

  test('user pause while background prevents lifecycle autoplay', () async {
    await player.open(source);
    player.didChangeAppLifecycleState(AppLifecycleState.paused);
    await player.pause();
    player.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(native.named('play'), isEmpty);
  });

  test(
    'background opt-out keeps playback but never runs recovery there',
    () async {
      await player.dispose();
      create(background: true);
      await player.open(source);
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await flush(180);
      expect(native.named('pause'), isEmpty);
      expect(native.named('open'), hasLength(1));
    },
  );

  test('open in background disables autoplay', () async {
    player.didChangeAppLifecycleState(AppLifecycleState.paused);
    await player.open(source);
    final config =
        (native.named('open').single.arguments as Map)['config'] as Map;
    expect(config['autoPlay'], isFalse);
    player.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(native.named('play'), hasLength(1));
  });

  test(
    'pause while create is pending changes config before native open',
    () async {
      final gate = Completer<void>();
      native.intercept = (call) async {
        if (call.method == 'create') await gate.future;
        return native.respond(call);
      };
      final opening = player.open(source);
      await flush();
      final pausing = player.pause();
      gate.complete();
      await opening;
      await pausing;
      final config =
          (native.named('open').single.arguments as Map)['config'] as Map;
      expect(config['autoPlay'], isFalse);
      expect(native.named('play'), isEmpty);
    },
  );

  test(
    'background while open is pending applies pause on late initialization',
    () async {
      final gate = Completer<void>();
      native.intercept = (call) async {
        if (call.method == 'open') await gate.future;
        return native.respond(call);
      };
      final opening = player.open(source);
      await flush();
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      gate.complete();
      await opening;
      await flush();
      expect(native.named('pause'), isNotEmpty);
      expect(native.named('play'), isEmpty);
      await flush(180);
      expect(native.named('open'), hasLength(1));
    },
  );

  test('pause cancels recovery already waiting behind a command', () async {
    await player.open(source);
    final gate = Completer<void>();
    native.intercept = (call) async {
      if (call.method == 'volume') await gate.future;
      return native.respond(call);
    };
    final volume = player.setVolume(.5);
    await flush();
    await native.emit({
      'id': 1,
      'type': 'error',
      'code': 'network',
      'message': 'Temporary network error',
      'recoverable': true,
    });
    await flush(35);
    final pausing = player.pause();
    gate.complete();
    await volume;
    await pausing;
    await flush(70);
    expect(native.named('open'), hasLength(1));
  });

  test(
    'pause during recovery open prevents late autoplay restoration',
    () async {
      await player.open(source);
      final gate = Completer<void>();
      native.intercept = (call) async {
        if (call.method == 'open') await gate.future;
        return native.respond(call);
      };
      await native.emit({
        'id': 1,
        'type': 'error',
        'code': 'network',
        'message': 'Temporary network error',
        'recoverable': true,
      });
      await flush(40);
      expect(native.named('open'), hasLength(2));
      final pausing = player.pause();
      gate.complete();
      await pausing;
      await flush(180);
      expect(native.named('open'), hasLength(2));
      expect(native.named('play'), isEmpty);
      expect(native.named('pause'), isNotEmpty);
    },
  );

  test(
    'background cancels a retry and foreground can recover existing error',
    () async {
      await player.open(source);
      await native.emit({
        'id': 1,
        'type': 'error',
        'code': 'network',
        'message': 'Temporary network error',
        'recoverable': true,
      });
      await flush();
      player.didChangeAppLifecycleState(AppLifecycleState.paused);
      await flush(100);
      expect(native.named('open'), hasLength(1));
      player.didChangeAppLifecycleState(AppLifecycleState.resumed);
      await flush(40);
      expect(native.named('open'), hasLength(2));
    },
  );

  test('stale guarded scrubbing pause cannot cancel play intent', () async {
    await player.open(source);
    await expectLater(player.pause(isCurrent: () => false), throwsStateError);
    player.didChangeAppLifecycleState(AppLifecycleState.paused);
    await flush();
    player.didChangeAppLifecycleState(AppLifecycleState.resumed);
    await flush();
    expect(native.named('play'), hasLength(1));
  });

  test(
    'playlist selection invalidates recovery for the previous item',
    () async {
      native.uninstall();
      final playlistNative = NativePlaylistFake()..install();
      try {
        await player.openPlaylist(samplePlaylist());
        await playlistNative.emit({
          'id': 1,
          'type': 'error',
          'code': 'network',
          'message': 'Temporary network error',
          'recoverable': true,
          'playlistIndex': 0,
        });
        await flush();
        await player.next();
        await flush(70);
        expect(player.playlistIndex, 1);
        expect(playlistNative.named('openPlaylist'), hasLength(1));
        expect(playlistNative.named('selectPlaylistItem'), hasLength(1));
      } finally {
        await player.dispose();
        playlistNative.uninstall();
      }
    },
  );

  test('observer is registered and removed on disposal', () async {
    await player.open(source);
    final binding = WidgetsBinding.instance;
    try {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
      await flush();
      expect(native.named('pause'), hasLength(1));
      await player.dispose();
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await flush();
      expect(native.named('play'), isEmpty);
    } finally {
      binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    }
  });

  test('native Android and iOS report custom headers support', () {
    for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
      debugDefaultTargetPlatformOverride = platform;
      expect(player.capabilities.httpHeaders, isTrue);
    }
  });
}
