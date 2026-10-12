import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;
import 'playlist_test.dart' show NativePlaylistFake, flushNativeEvents;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('ranges validate, snapshot lists and merge partial events', () {
    final range = LumioBufferedRange(
      start: const Duration(seconds: 1),
      end: const Duration(seconds: 3),
    );
    final input = [range];
    final state = LumioPlayerState(buffered: input);
    input.clear();
    expect(state.buffered, [range]);
    expect(() => state.buffered.clear(), throwsUnsupportedError);
    expect(state.copyWith(playing: true).buffered, [range]);
    expect(state.apply({'positionMs': 2000}).buffered, [range]);
    expect(LumioPlayerState().buffered, isEmpty);
    expect(
      () => LumioBufferedRange(
        start: const Duration(seconds: -1),
        end: Duration.zero,
      ),
      throwsArgumentError,
    );
    expect(
      () => LumioBufferedRange(
        start: const Duration(seconds: 1),
        end: Duration.zero,
      ),
      throwsArgumentError,
    );
    final parsed = state.apply({
      'bufferedPositionMs': 9000,
      'bufferedRanges': [
        {'startMs': 1000.9, 'endMs': 3000.4},
        {'startMs': 6000, 'endMs': 9000},
        {'startMs': -1, 'endMs': 1},
        {'startMs': 4, 'endMs': 3},
        {'startMs': double.nan, 'endMs': 3},
        {'startMs': 0, 'endMs': double.infinity},
        {'startMs': '0', 'endMs': 3},
        null,
      ],
    });
    expect(parsed.buffered, [
      range,
      LumioBufferedRange(
        start: const Duration(seconds: 6),
        end: const Duration(seconds: 9),
      ),
    ]);
    expect(parsed.bufferedPosition, const Duration(seconds: 9));
    expect(() => parsed.buffered.add(range), throwsUnsupportedError);
    expect(parsed.apply({'bufferedRanges': []}).buffered, isEmpty);
    expect(parsed.apply({'bufferedRanges': null}).buffered, isEmpty);
  });

  group('native contracts', () {
    late NativeMock native;
    late LumioPlayerController player;
    final source = LumioSource.network(
      Uri.parse('https://example.com/video.mp4'),
    );
    setUp(() {
      native = NativeMock()..install();
      player = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          engine: LumioPlaybackEngine.native,
          autoPlay: false,
        ),
      );
    });
    tearDown(() async {
      await player.dispose();
      native.uninstall();
      debugDefaultTargetPlatformOverride = null;
    });

    test('texture default preserves create wire arguments', () async {
      await player.open(source);
      expect(native.named('create').single.arguments, isNull);
      expect(player.nativeViewType, LumioNativeViewType.texture);
      expect(player.nativePlayerId, 1);
      expect(player.textureId, 101);
      debugDefaultTargetPlatformOverride = TargetPlatform.android;
      expect(player.capabilities.nativePlatformView, isTrue);
      expect(player.capabilities.supportsSurfaceCapture, isTrue);
    });

    test(
      'platform mode accepts id without texture and reports capture limits',
      () async {
        await player.dispose();
        player = LumioPlayerController(
          configuration: const LumioPlayerConfiguration(
            engine: LumioPlaybackEngine.native,
            nativeViewType: LumioNativeViewType.platformView,
          ),
        );
        native.intercept = (call) async =>
            call.method == 'create' ? {'id': 7} : await native.respond(call);
        await player.open(source);
        expect(native.named('create').single.arguments, {
          'viewType': 'platformView',
        });
        expect(player.nativePlayerId, 7);
        expect(player.textureId, isNull);
        debugDefaultTargetPlatformOverride = TargetPlatform.iOS;
        expect(player.capabilities.nativePlatformView, isTrue);
        expect(player.capabilities.supportsSurfaceCapture, isFalse);
      },
    );

    test(
      'position is queried while paused, not read from cached state',
      () async {
        expect(await player.getPosition(), isNull);
        expect(native.named('getPosition'), isEmpty);
        await player.open(source);
        await player.pause();
        player.value = player.value.copyWith(
          position: const Duration(seconds: 1),
        );
        native.intercept = (call) async =>
            call.method == 'getPosition' ? 4321 : await native.respond(call);
        expect(await player.getPosition(), const Duration(milliseconds: 4321));
        expect(native.named('getPosition').single.arguments, {'id': 1});
        expect(player.value.position, const Duration(milliseconds: 4321));
        expect(player.value.playing, isFalse);
      },
    );

    for (final replacement in ['source', 'engine', 'pause', 'dispose']) {
      test(
        '$replacement invalidates a pending query without updating state',
        () async {
          await player.open(source);
          final reply = Completer<Object?>();
          native.intercept = (call) => call.method == 'getPosition'
              ? reply.future
              : native.respond(call);
          final query = expectLater(player.getPosition(), throwsStateError);
          await Future<void>.delayed(Duration.zero);
          await Future<void>.delayed(Duration.zero);
          final Future<void> change;
          switch (replacement) {
            case 'source':
              change = player.open(
                LumioSource.network(Uri.parse('https://example.com/new.mp4')),
              );
            case 'engine':
              change = player.setEngine(LumioPlaybackEngine.native);
            case 'pause':
              change = player.pause();
            default:
              change = player.dispose();
          }
          reply.complete(9999);
          await query;
          await change;
          expect(
            player.value.position,
            isNot(const Duration(milliseconds: 9999)),
          );
          if (replacement == 'dispose') {
            await expectLater(player.getPosition(), throwsStateError);
          }
        },
      );
    }

    test(
      'source replacement clears ranges and legacy buffered position',
      () async {
        await player.open(source);
        player.value = player.value.apply({
          'bufferedPositionMs': 3000,
          'bufferedRanges': [
            {'startMs': 0, 'endMs': 3000},
          ],
        });
        await player.open(source);
        expect(player.value.buffered, isEmpty);
        expect(player.value.bufferedPosition, Duration.zero);
      },
    );
  });

  test(
    'manual and automatic playlist changes do not retain old ranges',
    () async {
      final native = NativePlaylistFake()..install();
      final player = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          engine: LumioPlaybackEngine.native,
        ),
      );
      try {
        await player.openPlaylist(
          LumioPlaylist([
            LumioPlaylistItem(
              source: LumioSource.network(
                Uri.parse('https://example.com/one.mp4'),
              ),
            ),
            LumioPlaylistItem(
              source: LumioSource.network(
                Uri.parse('https://example.com/two.mp4'),
              ),
            ),
          ]),
        );
        await native.state(
          extra: {
            'bufferedPositionMs': 5000,
            'bufferedRanges': [
              {'startMs': 0, 'endMs': 5000},
            ],
          },
        );
        await flushNativeEvents();
        expect(player.value.buffered, hasLength(1));
        await player.next();
        expect(player.value.buffered, isEmpty);
        expect(player.value.bufferedPosition, Duration.zero);
        await native.state(
          extra: {
            'bufferedPositionMs': 5000,
            'bufferedRanges': [
              {'startMs': 0, 'endMs': 5000},
            ],
          },
        );
        await flushNativeEvents();
        native.index = 0;
        await native.state();
        await flushNativeEvents();
        expect(player.playlistIndex, 0);
        expect(player.value.buffered, isEmpty);
        expect(player.value.bufferedPosition, Duration.zero);
      } finally {
        await player.dispose();
        native.uninstall();
      }
    },
  );
}
