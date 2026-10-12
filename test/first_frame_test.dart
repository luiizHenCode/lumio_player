import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';
import 'package:lumio_player/src/failure_report.dart';

import 'controller_test.dart' show NativeMock;
import 'player_view_test.dart' show TestController, host, close;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeMock native;
  late LumioPlayerController player;
  final source = LumioSource.network(
    Uri.parse('https://example.com/video.mp4'),
  );
  Future<void> flush() => Future<void>.delayed(Duration.zero);
  Future<void> state(Map<String, Object?> data, {int? id}) async {
    await native.emit({
      'id': id ?? native.nextId - 1,
      'type': 'state',
      ...data,
    });
    await flush();
  }

  const frame = {
    'hasRenderedFirstFrame': true,
    'firstFrameSupported': true,
    'firstFrameEvidence': 'renderer',
  };
  setUp(() {
    native = NativeMock()..install();
    player = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        allowAutomaticFallback: false,
      ),
    );
  });
  tearDown(() async {
    await player.dispose();
    native.uninstall();
  });

  test(
    'diagnostics includes current phase, frame evidence and startup timeline',
    () async {
      await player.open(source);
      await state({
        ...frame,
        'initialized': true,
        'playing': true,
        'buffering': false,
      });
      native.intercept = (call) async => call.method == 'diagnostics'
          ? <String, Object?>{}
          : native.respond(call);
      final snapshot = await player.diagnostics();
      expect(snapshot['phase'], 'playing');
      expect(snapshot['hasRenderedFirstFrame'], true);
      expect(snapshot['firstFrameSupported'], true);
      expect(snapshot['firstFrameEvidence'], 'renderer');
      final startup = snapshot['startup'] as Map;
      expect(startup['attempt'], 1);
      expect(startup['readinessElapsedMs'], isA<int>());
      expect(startup['firstFrameElapsedMs'], isA<int>());
      expect(startup['events'], isNotEmpty);
    },
  );

  testWidgets(
    'frame loader preserves enabled controls and compact presentation',
    (tester) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          playing: true,
          firstFrameSupported: true,
        );
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(
            compact: true,
            compactDelay: Duration(seconds: 1),
          ),
        ),
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('lumio-loading-indicator')),
        findsOneWidget,
      );
      for (final button in tester.widgetList<IconButton>(
        find.byType(IconButton),
      )) {
        if (button.tooltip == 'Pause') expect(button.onPressed, isNotNull);
      }
      controller.value = controller.value.copyWith(
        hasRenderedFirstFrame: true,
        firstFrameEvidence: LumioFirstFrameEvidence.renderer,
      );
      await tester.pump();
      expect(
        find.byKey(const ValueKey('lumio-loading-indicator')),
        findsNothing,
      );
      await close(tester, controller);
    },
  );

  test(
    'phases notify observers and trace stays capped and immutable',
    () async {
      final phases = <LumioPlaybackPhase>[];
      player.addListener(() => phases.add(player.phase));
      await player.open(source);
      expect(
        phases,
        containsAllInOrder([
          LumioPlaybackPhase.connecting,
          LumioPlaybackPhase.preparing,
          LumioPlaybackPhase.playing,
        ]),
      );
      await state(frame);
      final before = player.startupDiagnostics;
      final beforeEvents = List.of(before['events'] as List);
      for (var i = 0; i < 80; i++) {
        await state({'playing': i.isEven, 'buffering': i.isOdd});
      }
      final events = player.startupDiagnostics['events'] as List;
      expect(events, hasLength(32));
      expect(before['events'], beforeEvents);
      var lastElapsed = 0;
      for (final event in events.cast<Map>()) {
        expect(event.keys, unorderedEquals(['stage', 'elapsedMs']));
        expect(event['elapsedMs'], greaterThanOrEqualTo(lastElapsed));
        lastElapsed = event['elapsedMs'] as int;
      }
    },
  );

  test('legacy and invalid evidence stay conservative', () {
    final initial = LumioPlayerState();
    expect(initial.hasRenderedFirstFrame, false);
    expect(initial.firstFrameSupported, false);
    expect(initial.firstFrameEvidence, isNull);
    for (final evidence in [null, 'secret/path', 42]) {
      final state = initial.apply({...frame, 'firstFrameEvidence': evidence});
      expect(state.hasRenderedFirstFrame, false);
      expect(state.firstFrameEvidence, isNull);
    }
    expect(
      initial.apply({
        ...frame,
        'firstFrameSupported': false,
      }).hasRenderedFirstFrame,
      false,
    );
  });

  test(
    'ready open and commands do not await frame; stage and first evidence latch',
    () async {
      await player.open(source);
      await state({'firstFrameSupported': true});
      expect(player.value.initialized, true);
      expect(player.value.phase, LumioPlaybackPhase.ready);
      expect(player.awaitingFirstFrame, true);
      expect(player.startupDiagnostics['readinessElapsedMs'], isA<int>());
      expect(player.startupDiagnostics['playbackStartedElapsedMs'], isA<int>());
      expect(player.startupDiagnostics['firstFrameElapsedMs'], isNull);
      await player.pause();
      expect(player.awaitingFirstFrame, false);
      await player.play();
      expect(player.awaitingFirstFrame, true);
      await state(frame);
      final snapshot = player.startupDiagnostics;
      expect(player.phase, LumioPlaybackPhase.playing);
      expect(snapshot['firstFrameElapsedMs'], isA<int>());
      await state({...frame, 'firstFrameEvidence': 'pixelBuffer'});
      expect(player.value.firstFrameEvidence, LumioFirstFrameEvidence.renderer);
      expect(
        player.startupDiagnostics['firstFrameElapsedMs'],
        snapshot['firstFrameElapsedMs'],
      );
      expect(() => snapshot['attempt'] = 9, throwsUnsupportedError);
      expect(
        () => (snapshot['events'] as List).clear(),
        throwsUnsupportedError,
      );
      expect(
        () => ((snapshot['events'] as List).first as Map)['stage'] = 'secret',
        throwsUnsupportedError,
      );
      expect(
        (snapshot['firstFrameElapsedMs'] as int),
        greaterThanOrEqualTo(snapshot['readinessElapsedMs'] as int),
      );
    },
  );

  test(
    'paused open, audio mode and video with no audio never await first frame',
    () async {
      await player.dispose();
      player = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          engine: LumioPlaybackEngine.native,
          autoPlay: false,
        ),
      );
      await player.open(source);
      await state({'firstFrameSupported': true, 'hasAudio': false});
      expect(player.value.initialized, true);
      expect(player.awaitingFirstFrame, false);
      await player.dispose();
      player = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          engine: LumioPlaybackEngine.native,
          mode: LumioPlaybackMode.audio,
        ),
      );
      await player.open(source);
      await state({'firstFrameSupported': true});
      expect(player.awaitingFirstFrame, false);
      expect(player.phase, LumioPlaybackPhase.playing);
    },
  );

  test(
    'retry and new source reset attempt timing and ignore old/disposed evidence',
    () async {
      await player.open(source);
      await state(frame);
      final old = player.startupDiagnostics;
      await player.retry();
      expect(player.startupDiagnostics['attempt'], 2);
      expect(player.startupDiagnostics['firstFrameElapsedMs'], isNull);
      expect(player.value.firstFrameSupported, false);
      await state(frame, id: 1);
      expect(player.value.hasRenderedFirstFrame, false);
      await player.open(
        LumioSource.network(Uri.parse('https://example.com/new.mp4')),
      );
      expect(player.startupDiagnostics['attempt'], 3);
      expect(old['attempt'], 1);
      expect(old['firstFrameElapsedMs'], isA<int>());
      await player.dispose();
      final disposed = player.startupDiagnostics;
      await state(frame);
      expect(player.startupDiagnostics, disposed);
      expect(player.value.hasRenderedFirstFrame, false);
    },
  );

  for (final targetIndex in [0, 1]) {
    test(
      'native epoch rejects stale selection snapshots for index $targetIndex',
      () async {
        final secondSource = LumioSource.network(
          Uri.parse('https://example.com/second.mp4'),
        );
        native.intercept = (call) async {
          if (call.method == 'openPlaylist') {
            await state({
              'initialized': true,
              'buffering': false,
              'playlistIndex': 0,
              'selectionEpoch': 0,
            });
            return null;
          }
          if (call.method == 'selectPlaylistItem') return null;
          return native.respond(call);
        };
        await player.openPlaylist(
          LumioPlaylist([
            LumioPlaylistItem(source: source),
            LumioPlaylistItem(source: secondSource),
          ]),
        );
        await state({...frame, 'selectionEpoch': 0, 'playlistIndex': 0});
        var completed = false;
        final selecting = player
            .selectPlaylistItem(targetIndex)
            .then((_) => completed = true);
        await flush();
        expect(native.named('selectPlaylistItem').last.arguments, {
          'id': 1,
          'index': targetIndex,
          'selectionEpoch': 1,
        });
        final pendingState = player.value;
        final pendingStartup = player.startupDiagnostics;
        for (final epoch in [0, 2]) {
          await state({
            ...frame,
            'initialized': true,
            'playing': true,
            'playlistIndex': 0,
            'selectionEpoch': epoch,
          });
          expect(player.value, same(pendingState));
          expect(player.playlistIndex, targetIndex);
          expect(
            player.startupDiagnostics['attempt'],
            pendingStartup['attempt'],
          );
          expect(player.startupDiagnostics['events'], pendingStartup['events']);
          expect(player.startupDiagnostics['readinessElapsedMs'], isNull);
          expect(player.startupDiagnostics['firstFrameElapsedMs'], isNull);
          expect(completed, false);
        }
        await state({
          'selectionEpoch': 1,
          'playlistIndex': targetIndex,
          'initialized': false,
          'firstFrameSupported': true,
          'hasRenderedFirstFrame': false,
        });
        expect(player.value.hasRenderedFirstFrame, false);
        expect(player.value.firstFrameEvidence, isNull);
        expect(completed, false);
        await state({
          'selectionEpoch': 1,
          'playlistIndex': targetIndex,
          'initialized': true,
          'buffering': false,
          'hasRenderedFirstFrame': false,
        });
        await selecting;
        expect(completed, true);
        expect(player.value.hasRenderedFirstFrame, false);
        expect(player.startupDiagnostics['firstFrameElapsedMs'], isNull);
        expect(player.source, same(targetIndex == 0 ? source : secondSource));
        // A real automatic item change retains the current selection epoch.
        final automaticIndex = 1 - targetIndex;
        await state({
          'selectionEpoch': 1,
          'playlistIndex': automaticIndex,
          'initialized': true,
          'firstFrameSupported': true,
          'hasRenderedFirstFrame': false,
        });
        expect(player.playlistIndex, automaticIndex);
        expect(
          player.source,
          same(automaticIndex == 0 ? source : secondSource),
        );
        expect(player.startupDiagnostics['attempt'], 3);
        final nextSelection = player.selectPlaylistItem(automaticIndex);
        await flush();
        expect(
          (native.named('selectPlaylistItem').last.arguments
              as Map)['selectionEpoch'],
          2,
        );
        await state({
          'selectionEpoch': 2,
          'playlistIndex': automaticIndex,
          'initialized': true,
        });
        await nextSelection;
        await player.retry();
        final restarted = player.value;
        await state({...frame, 'selectionEpoch': 2, 'initialized': true});
        expect(player.value, same(restarted));
        await state({...frame, 'selectionEpoch': 0, 'initialized': true});
        expect(player.value.hasRenderedFirstFrame, true);
      },
    );
  }

  test('legacy pending selection ignores a mismatched old index', () async {
    native.intercept = (call) async {
      if (call.method == 'openPlaylist') {
        await state({'initialized': true, 'playlistIndex': 0});
        return null;
      }
      if (call.method == 'selectPlaylistItem') return null;
      return native.respond(call);
    };
    await player.openPlaylist(
      LumioPlaylist([
        LumioPlaylistItem(source: source),
        LumioPlaylistItem(source: source),
      ]),
    );
    final selecting = player.selectPlaylistItem(1);
    await flush();
    final pending = player.value;
    await state({...frame, 'playlistIndex': 0, 'initialized': true});
    expect(player.value, same(pending));
    expect(player.playlistIndex, 1);
    expect(player.startupDiagnostics['readinessElapsedMs'], isNull);
    await state({
      'playlistIndex': 1,
      'initialized': true,
      'hasRenderedFirstFrame': false,
    });
    await selecting;
    expect(player.value.hasRenderedFirstFrame, false);
  });

  test('same-item and new-item selection reset frame and attempt', () async {
    native.intercept = (call) async {
      if (call.method == 'openPlaylist' ||
          call.method == 'selectPlaylistItem') {
        await native.emit({
          'id': 1,
          'type': 'state',
          'initialized': true,
          'buffering': false,
        });
        return null;
      }
      return native.respond(call);
    };
    await player.openPlaylist(
      LumioPlaylist([
        LumioPlaylistItem(source: source),
        LumioPlaylistItem(source: source),
      ]),
    );
    await state(frame);
    await player.selectPlaylistItem(0);
    expect(player.value.hasRenderedFirstFrame, false);
    expect(player.startupDiagnostics['attempt'], 2);
    await state(frame);
    await player.selectPlaylistItem(1);
    expect(player.value.firstFrameEvidence, isNull);
    expect(player.startupDiagnostics['attempt'], 3);
  });

  test(
    'failure snapshot retains attempt timings after replacement without unsafe metadata',
    () async {
      await player.open(source);
      await state(frame);
      await native.emit({
        'id': 1,
        'type': 'error',
        'code': 'network',
        'message': '/Users/secret https://secret/token',
      });
      await flush();
      final report = (await player.failureReport())!;
      final startup = report.metadata['startup'] as Map;
      expect(startup['stage'], 'failed');
      expect(startup['attempt'], 1);
      expect(startup['evidence'], 'renderer');
      expect(startup['firstFrameElapsedMs'], isA<int>());
      await player.retry();
      expect((await player.failureReport())!.metadata['startup'], startup);
      expect(player.startupDiagnostics['attempt'], 2);
      expect(jsonEncode(startup), isNot(contains('secret')));
    },
  );

  test('failure allowlists accept only safe timings stages and evidence', () {
    expect(
      safeFailureDiagnostics({
        'startup': {
          'attempt': 2,
          'elapsedMs': 12,
          'readinessElapsedMs': 5,
          'firstFrameElapsedMs': double.infinity,
          'stage': 'ready',
          'evidence': '/private/token',
          'url': 'https://secret',
          'events': [
            {'stage': 'connecting', 'elapsedMs': 0, 'message': 'secret'},
          ],
        },
      }),
      {
        'startup': {
          'attempt': 2,
          'elapsedMs': 12,
          'readinessElapsedMs': 5,
          'stage': 'ready',
          'events': [
            {'stage': 'connecting', 'elapsedMs': 0},
          ],
        },
      },
    );
  });

  test(
    'native create failure records unknown milestones before cleanup',
    () async {
      native.intercept = (call) async {
        if (call.method == 'create') {
          throw PlatformException(code: 'open_failed');
        }
        return native.respond(call);
      };
      await expectLater(player.open(source), throwsA(isA<LumioPlayerError>()));
      final startup =
          (await player.failureReport())!.metadata['startup'] as Map;
      expect(startup['attempt'], 1);
      expect(startup['createElapsedMs'], isNull);
      expect(startup['readinessElapsedMs'], isNull);
      expect(startup['stage'], 'failed');
    },
  );
}
