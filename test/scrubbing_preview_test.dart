import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/controller.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

import 'controller_test.dart' show NativeMock;
import 'player_view_test.dart' show TestController, close, host;

class ScrubController extends TestController {
  final commands = <String>[];
  Completer<void>? pauseGate, seekGate;
  bool failPause = false, failSeek = false, failPlay = false;
  int activeSeeks = 0, maxSeeks = 0;

  @override
  Future<void> pause({bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    commands.add('pause');
    await pauseGate?.future;
    if (failPause) throw StateError('https://secret.invalid/token');
    await super.pause();
  }

  @override
  Future<void> seekTo(Duration position, {bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    commands.add('seek:${position.inMilliseconds}');
    activeSeeks++;
    if (activeSeeks > maxSeeks) maxSeeks = activeSeeks;
    try {
      await seekGate?.future;
      if (failSeek) throw StateError('https://secret.invalid/token');
      await super.seekTo(position);
    } finally {
      activeSeeks--;
    }
  }

  @override
  Future<void> play({bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    commands.add('play');
    if (failPlay) throw StateError('https://secret.invalid/token');
    await super.play();
  }
}

const preview = LumioControlsConfiguration(previewWhileScrubbing: true);

ScrubController controller({bool playing = true}) => ScrubController()
  ..testSource = LumioSource.network(Uri.parse('https://example.com/video'))
  ..value = LumioPlayerState(
    initialized: true,
    playing: playing,
    duration: const Duration(seconds: 100),
  );

Widget controls(
  LumioPlayerController controller, {
  LumioControlsConfiguration configuration = preview,
  ValueChanged<bool>? onInteraction,
}) => MaterialApp(
  home: Scaffold(
    body: LumioPlayerControls(
      controller: controller,
      configuration: configuration,
      onInteraction: onInteraction,
    ),
  ),
);

Slider slider(WidgetTester tester) =>
    tester.widget<Slider>(find.byKey(const ValueKey('lumio-progress')));

Future<void> flush(WidgetTester tester) async {
  for (var i = 0; i < 16; i++) {
    await tester.pump();
  }
}

void main() {
  for (final stage in ['pause', 'preview', 'final', 'play', 'restore']) {
    testWidgets(
      'real queued open rejects stale scrub $stage on new native engine',
      (tester) async {
        final native = NativeMock()..install();
        final logs = <LumioLogEntry>[];
        final c = LumioPlayerController(
          configuration: const LumioPlayerConfiguration(
            engine: LumioPlaybackEngine.native,
            allowAutomaticFallback: false,
          ),
          logger: logs.add,
        );
        final a = LumioSource.network(Uri.parse('https://example.com/a'));
        final b = LumioSource.network(Uri.parse('https://example.com/b'));
        final openingA = c.open(a);
        await flush(tester);
        await openingA;
        await native.emit({'id': 1, 'type': 'state', 'durationMs': 100000});
        await flush(tester);
        await tester.pumpWidget(controls(c));
        if (stage != 'pause') {
          slider(tester).onChangeStart!(0);
          await flush(tester);
          expect(native.named('pause'), hasLength(1));
        }
        final gate = Completer<Object?>();
        Future<void>? blocker, openingB;
        void queueOpen() {
          blocker = c.setVolume(.5);
          openingB = c.open(b);
        }

        native.intercept = (call) async {
          if (call.method == 'volume') return gate.future;
          if (stage == 'play' && call.method == 'seek') queueOpen();
          return native.respond(call);
        };
        logs.clear();
        final before = native.calls.length;
        if (stage == 'play') {
          slider(tester).onChangeEnd!(20000);
          await flush(tester);
        } else {
          queueOpen();
          // The blocker is executing, but open(B) has not changed source yet.
          await flush(tester);
          switch (stage) {
            case 'pause':
              slider(tester).onChangeStart!(0);
            case 'preview':
              slider(tester).onChanged!(20000);
            case 'final':
              slider(tester).onChangeEnd!(20000);
            case 'restore':
              await tester.pumpWidget(const SizedBox.shrink());
          }
          await flush(tester);
        }
        expect(c.source, same(a));
        expect(native.named('volume'), hasLength(1));
        gate.complete(null);
        await flush(tester);
        await blocker;
        await openingB;
        expect(c.source, same(b));
        expect(native.named('open'), hasLength(2));
        final scrubCommands = native.calls
            .skip(before)
            .where((call) => ['pause', 'seek', 'play'].contains(call.method));
        expect(
          scrubCommands.map((call) => call.method),
          stage == 'play' ? ['seek'] : isEmpty,
        );
        for (final call in scrubCommands) {
          expect((call.arguments as Map)['id'], 1);
        }
        // Proves the stale queued command actually failed, rather than just being
        // skipped by a pre-queue identity check or reported as a successful seek.
        expect(
          logs.where((entry) => entry.code == 'controls_command_failed'),
          hasLength(1),
        );
        expect(native.named('play'), isEmpty);
        expect(tester.takeException(), isNull);
        await close(tester, c);
        native.uninstall();
      },
    );
  }

  testWidgets('dispose balances captured interaction/scrubbing after frame', (
    tester,
  ) async {
    final c = controller();
    final interactions = <bool>[];
    final scrubs = <bool>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LumioPlayerControls(
            controller: c,
            configuration: preview,
            onInteraction: interactions.add,
            onScrubbingChanged: scrubs.add,
          ),
        ),
      ),
    );
    slider(tester).onChangeStart!(0);
    await tester.pump();
    expect(interactions, [true]);
    expect(scrubs, [true]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(interactions, [true, false]);
    expect(scrubs, [true, false]);
    expect(tester.takeException(), isNull);
    await c.dispose();
  });

  testWidgets(
    'controls off/on allows compact again and parent dispose is safe',
    (tester) async {
      final c = controller();
      const config = LumioControlsConfiguration(
        previewWhileScrubbing: true,
        compact: true,
        compactDelay: Duration(milliseconds: 200),
      );
      await tester.pumpWidget(host(c, configuration: config));
      slider(tester).onChangeStart!(0);
      await tester.pump();
      await tester.pumpWidget(host(c, controls: false, configuration: config));
      await tester.pump();
      await tester.pumpWidget(host(c, configuration: config));
      await tester.pump(const Duration(milliseconds: 201));
      expect(
        find.byKey(const ValueKey('lumio-compact-controls')),
        findsOneWidget,
      );
      await tester.tap(find.byKey(const ValueKey('lumio-compact-controls')));
      await tester.pump();
      slider(tester).onChangeStart!(0);
      await tester.pump();
      await close(tester, c);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets(
    'preview hides buffering loader through final seek, not other buffering',
    (tester) async {
      final c = controller();
      await tester.pumpWidget(host(c, configuration: preview));
      c.value = c.value.copyWith(buffering: true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      c.seekGate = Completer<void>();
      slider(tester).onChangeEnd!(20000);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      c.seekGate!.complete();
      await flush(tester);
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      c.value = c.value.copyWith(buffering: false);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsNothing);
      c.value = c.value.copyWith(buffering: true);
      await tester.pump();
      expect(find.byType(CircularProgressIndicator), findsOneWidget);
      await close(tester, c);
      expect(tester.takeException(), isNull);
    },
  );

  testWidgets('controls off/on revokes old pending pause across States', (
    tester,
  ) async {
    final native = NativeMock()..install();
    final c = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        allowAutomaticFallback: false,
      ),
    );
    final opening = c.open(
      LumioSource.network(Uri.parse('https://example.com/video')),
    );
    await flush(tester);
    await opening;
    await native.emit({'id': 1, 'type': 'state', 'durationMs': 100000});
    await flush(tester);
    final oldPause = Completer<Object?>();
    var pauses = 0;
    native.intercept = (call) {
      if (call.method == 'pause' && ++pauses == 1) return oldPause.future;
      return native.respond(call);
    };
    await tester.pumpWidget(host(c, configuration: preview));
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(10000);
    await flush(tester);
    expect(native.named('pause'), hasLength(1));
    await tester.pumpWidget(host(c, controls: false, configuration: preview));
    await tester.pumpWidget(host(c, configuration: preview));
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(30000);
    await flush(tester);
    expect(native.named('seek'), isEmpty);
    oldPause.complete(null);
    await flush(tester);
    expect(native.named('pause'), hasLength(2));
    expect(native.named('play'), isEmpty);
    expect(native.named('seek').single.arguments, {
      'id': 1,
      'positionMs': 30000,
      'waitForFrame': true,
    });
    await tester.pump(const Duration(milliseconds: 200));
    expect(native.named('play'), isEmpty);
    slider(tester).onChangeEnd!(40000);
    await flush(tester);
    expect(native.named('play'), hasLength(1));
    expect(
      native.calls
          .where((call) => ['pause', 'seek', 'play'].contains(call.method))
          .map((call) => call.method),
      ['pause', 'pause', 'seek', 'seek', 'play'],
    );
    expect(native.named('seek').last.arguments, {
      'id': 1,
      'positionMs': 40000,
      'waitForFrame': true,
    });
    await close(tester, c);
    native.uninstall();
    expect(tester.takeException(), isNull);
  });

  for (final change in ['source', 'controller']) {
    testWidgets(
      '$change swap reannounces new scrub while old cancellation is pending',
      (tester) async {
        final old = controller()..pauseGate = Completer<void>();
        final next = change == 'source' ? old : controller();
        await tester.pumpWidget(host(old, configuration: preview));
        slider(tester).onChangeStart!(0);
        slider(tester).onChanged!(10000);
        await flush(tester);
        old.value = old.value.copyWith(buffering: true);
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        if (change == 'source') {
          old.testSource = LumioSource.network(
            Uri.parse('https://example.com/new'),
          );
          old.notifyListeners();
        } else {
          next.value = next.value.copyWith(buffering: true);
        }
        await tester.pumpWidget(host(next, configuration: preview));
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        slider(tester).onChangeStart!(0);
        slider(tester).onChanged!(30000);
        await tester.pump();
        expect(find.byType(CircularProgressIndicator), findsNothing);
        old.pauseGate!.complete();
        await flush(tester);
        // The old cancellation must not send a false event over this new drag.
        expect(find.byType(CircularProgressIndicator), findsNothing);
        slider(tester).onChangeEnd!(40000);
        await flush(tester);
        expect(find.byType(CircularProgressIndicator), findsOneWidget);
        await close(tester, next);
        if (!identical(old, next)) await old.dispose();
        expect(tester.takeException(), isNull);
      },
    );
  }

  testWidgets('final seek clamps both bounds in preview and legacy modes', (
    tester,
  ) async {
    for (final config in [preview, const LumioControlsConfiguration()]) {
      final c = controller(playing: false);
      await tester.pumpWidget(controls(c, configuration: config));
      slider(tester).onChangeStart!(0);
      slider(tester).onChangeEnd!(200000);
      await tester.pump();
      expect(c.sought, const Duration(seconds: 100));
      slider(tester).onChangeStart!(0);
      slider(tester).onChangeEnd!(-1000);
      await tester.pump();
      expect(c.sought, Duration.zero);
      await close(tester, c);
    }
  });
  for (final layout in [
    LumioControlsLayout.complete,
    LumioControlsLayout.simplified,
  ]) {
    for (final playing in [false, true]) {
      testWidgets(
        '$layout keeps status stable during preview and final seek (playing=$playing)',
        (tester) async {
          final c = controller(playing: playing)..seekGate = Completer<void>();
          await tester.pumpWidget(
            controls(
              c,
              configuration: LumioControlsConfiguration(
                layout: layout,
                previewWhileScrubbing: true,
                pausedLabel: 'Em pausa',
                playingLabel: 'Em reprodução',
                loadingLabel: 'A carregar',
              ),
            ),
          );
          String? status() => tester
              .widget<Text>(find.byKey(const ValueKey('lumio-playback-status')))
              .data;
          expect(status(), playing ? 'Em reprodução' : 'Em pausa');
          slider(tester).onChangeStart!(0);
          slider(tester).onChanged!(10000);
          await tester.pump();
          expect(status(), 'Em pausa');
          for (final buffering in [true, false, true, false]) {
            c.value = c.value.copyWith(buffering: buffering);
            slider(tester).onChanged!(20000);
            await tester.pump(const Duration(milliseconds: 150));
            expect(status(), 'Em pausa');
          }
          slider(tester).onChangeEnd!(30000);
          c.value = c.value.copyWith(buffering: true);
          await tester.pump();
          expect(status(), 'Em pausa');
          c.value = c.value.copyWith(buffering: false);
          c.seekGate!.complete();
          c.seekGate = null;
          await tester.pump();
          expect(status(), playing ? 'Em reprodução' : 'Em pausa');
          c.value = c.value.copyWith(buffering: true);
          await tester.pump();
          expect(status(), 'A carregar');
          await close(tester, c);
        },
      );
    }
  }

  test('public defaults and interval validation', () {
    const defaults = LumioControlsConfiguration();
    expect(defaults.previewWhileScrubbing, isFalse);
    expect(defaults.scrubPreviewInterval, const Duration(milliseconds: 150));
    expect(
      () => const LumioControlsConfiguration(
        scrubPreviewInterval: Duration.zero,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LumioControlsConfiguration(
        scrubPreviewInterval: Duration(milliseconds: -1),
      ).validate(),
      throwsArgumentError,
    );
  });

  testWidgets('default seeks only at end without pause', (tester) async {
    final c = controller();
    await tester.pumpWidget(
      controls(c, configuration: const LumioControlsConfiguration()),
    );
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(10000);
    await tester.pump(const Duration(seconds: 1));
    expect(c.commands, isEmpty);
    slider(tester).onChangeEnd!(20000);
    await tester.pump();
    expect(c.commands, ['seek:20000']);
    await close(tester, c);
  });

  testWidgets(
    'coalesces, throttles continuous moves, flushes end and keeps thumb',
    (tester) async {
      final c = controller()..seekGate = Completer<void>();
      final interactions = <bool>[];
      await tester.pumpWidget(controls(c, onInteraction: interactions.add));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      expect(c.commands, ['pause', 'seek:10000']);
      slider(tester).onChanged!(20000);
      slider(tester).onChanged!(30000);
      c.value = c.value.copyWith(position: const Duration(seconds: 1));
      await tester.pump();
      expect(slider(tester).value, 30000);
      await tester.pump(const Duration(milliseconds: 150));
      expect(c.commands.length, 2);
      c.seekGate!.complete();
      c.seekGate = null;
      await tester.pump();
      expect(c.commands.last, 'seek:30000');
      slider(tester).onChanged!(40000);
      await tester.pump(const Duration(milliseconds: 75));
      slider(tester).onChanged!(50000);
      await tester.pump(const Duration(milliseconds: 75));
      expect(c.commands.last, 'seek:50000');
      slider(tester).onChangeEnd!(60000);
      await tester.pump();
      expect(c.commands.sublist(c.commands.length - 2), ['seek:60000', 'play']);
      expect(c.maxSeeks, 1);
      expect(interactions, [true, false]);
      await close(tester, c);
    },
  );

  testWidgets('end waits for pause and pending seek before play', (
    tester,
  ) async {
    final c = controller()..pauseGate = Completer<void>();
    await tester.pumpWidget(controls(c));
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(10000);
    await tester.pump();
    slider(tester).onChangeEnd!(20000);
    await tester.pump();
    expect(c.commands, ['pause']);
    c.seekGate = Completer<void>();
    c.pauseGate!.complete();
    await tester.pump();
    expect(c.commands, ['pause', 'seek:20000']);
    c.seekGate!.complete();
    await tester.pump();
    expect(c.commands, ['pause', 'seek:20000', 'play']);
    await close(tester, c);
  });

  testWidgets(
    'paused and accessibility discrete changes never stay in session',
    (tester) async {
      final c = controller(playing: false);
      await tester.pumpWidget(controls(c));
      slider(tester).onChanged!(10000);
      await tester.pump();
      expect(c.commands, ['seek:10000']);
      expect(slider(tester).value, 0);
      c.value = c.value.copyWith(playing: true);
      await tester.pump();
      slider(tester).onChanged!(20000);
      await tester.pump();
      expect(c.commands, ['seek:10000', 'pause', 'seek:20000', 'play']);
      await close(tester, c);
    },
  );

  for (final config in [
    const LumioControlsConfiguration(
      enabled: false,
      previewWhileScrubbing: true,
    ),
    const LumioControlsConfiguration(
      showProgress: false,
      previewWhileScrubbing: true,
    ),
    const LumioControlsConfiguration(),
    const LumioControlsConfiguration(
      layout: LumioControlsLayout.live,
      previewWhileScrubbing: true,
    ),
  ]) {
    testWidgets(
      'disable ${config.enabled}/${config.showProgress}/${config.previewWhileScrubbing}/${config.layout} restores original',
      (tester) async {
        final c = controller()..pauseGate = Completer<void>();
        await tester.pumpWidget(controls(c));
        slider(tester).onChangeStart!(0);
        slider(tester).onChanged!(10000);
        await tester.pump();
        await tester.pumpWidget(controls(c, configuration: config));
        c.pauseGate!.complete();
        await tester.pump();
        expect(c.commands, ['pause', 'play']);
        await tester.pump(const Duration(seconds: 1));
        expect(c.commands, ['pause', 'play']);
        expect(tester.takeException(), isNull);
        await close(tester, c);
      },
    );
  }

  for (final change in ['source', 'index', 'engine', 'live']) {
    testWidgets('$change invalidates preview with no stale seek/play', (
      tester,
    ) async {
      final c = controller()..seekGate = Completer<void>();
      await tester.pumpWidget(controls(c));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      slider(tester).onChanged!(20000);
      switch (change) {
        case 'source':
          c.testSource = LumioSource.network(
            Uri.parse('https://example.com/new'),
          );
        case 'index':
          c.testPlaylistIndex++;
        case 'engine':
          c.value = c.value.copyWith(engine: LumioPlaybackEngine.webview);
        case 'live':
          c.value = c.value.copyWith(live: true);
      }
      c.notifyListeners();
      c.seekGate!.complete();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(
        c.commands,
        change == 'live'
            ? ['pause', 'seek:10000', 'play']
            : ['pause', 'seek:10000'],
      );
      if (change == 'live') {
        expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
      }
      await close(tester, c);
    });
  }

  testWidgets('controller replacement restores only old media', (tester) async {
    final c = controller()..pauseGate = Completer<void>();
    final next = controller();
    await tester.pumpWidget(controls(c));
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(10000);
    await tester.pump();
    await tester.pumpWidget(controls(next));
    c.pauseGate!.complete();
    await tester.pump();
    expect(c.commands, ['pause', 'play']);
    expect(next.commands, isEmpty);
    await close(tester, next);
    await c.dispose();
  });

  testWidgets(
    'replacement drag does not steal restoration or playback intent',
    (tester) async {
      final old = controller()..pauseGate = Completer<void>();
      final next = controller(playing: false);
      await tester.pumpWidget(controls(old));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      await tester.pumpWidget(controls(next));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(30000);
      old.pauseGate!.complete();
      await tester.pump();
      slider(tester).onChangeEnd!(40000);
      await tester.pump();
      expect(old.commands, ['pause', 'play']);
      expect(next.commands, ['seek:30000', 'seek:40000']);
      await close(tester, next);
      await old.dispose();
    },
  );

  testWidgets(
    'new drag waits for old final seek and never resumes old session',
    (tester) async {
      final c = controller()..seekGate = Completer<void>();
      await tester.pumpWidget(controls(c));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      slider(tester).onChangeEnd!(20000);
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(30000);
      c.seekGate!.complete();
      c.seekGate = null;
      await tester.pump();
      expect(c.commands, ['pause', 'seek:10000', 'pause', 'seek:30000']);
      slider(tester).onChangeEnd!(40000);
      await tester.pump();
      expect(c.commands.last, 'play');
      expect(c.commands.where((e) => e == 'play').length, 1);
      await close(tester, c);
    },
  );

  testWidgets('unmount cancels timers and waits for pause to restore', (
    tester,
  ) async {
    final c = controller()..pauseGate = Completer<void>();
    await tester.pumpWidget(controls(c));
    slider(tester).onChangeStart!(0);
    slider(tester).onChanged!(10000);
    await tester.pump();
    await tester.pumpWidget(const SizedBox.shrink());
    c.pauseGate!.complete();
    await tester.pump();
    await tester.pump(const Duration(seconds: 1));
    expect(c.commands, ['pause', 'play']);
    expect(tester.takeException(), isNull);
    await c.dispose();
  });

  testWidgets(
    'pointer cancellation restores playback without flushing target',
    (tester) async {
      final c = controller();
      await tester.pumpWidget(controls(c));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(const ValueKey('lumio-progress'))),
      );
      await tester.pump();
      await gesture.moveBy(const Offset(50, 0));
      await tester.pump();
      expect(c.commands.first, 'pause');
      final seeks = c.commands.where((e) => e.startsWith('seek:')).length;
      await gesture.cancel();
      await tester.pump();
      await tester.pump(const Duration(seconds: 1));
      expect(c.commands.last, 'play');
      expect(c.commands.where((e) => e.startsWith('seek:')).length, seeks);
      expect(tester.takeException(), isNull);
      await close(tester, c);
    },
  );

  testWidgets(
    'failed preview can recover at final seek, paused drag never plays',
    (tester) async {
      final c = controller(playing: false)..failSeek = true;
      await tester.pumpWidget(controls(c));
      slider(tester).onChangeStart!(0);
      slider(tester).onChanged!(10000);
      await tester.pump();
      c.failSeek = false;
      slider(tester).onChangeEnd!(20000);
      await tester.pump();
      expect(c.commands, ['seek:10000', 'seek:20000']);
      expect(c.value.playing, isFalse);
      await close(tester, c);
    },
  );

  for (final failure in ['pause', 'seek', 'play']) {
    testWidgets(
      '$failure failure is sanitized and final failure does not resume',
      (tester) async {
        final c = controller()
          ..failPause = failure == 'pause'
          ..failSeek = failure == 'seek'
          ..failPlay = failure == 'play';
        await tester.pumpWidget(controls(c));
        slider(tester).onChangeStart!(0);
        slider(tester).onChangeEnd!(20000);
        await tester.pump();
        expect(tester.takeException(), isNull);
        expect(find.textContaining('secret.invalid'), findsNothing);
        expect(
          c.commands,
          failure == 'pause'
              ? ['pause']
              : failure == 'seek'
              ? ['pause', 'seek:20000']
              : ['pause', 'seek:20000', 'play'],
        );
        await close(tester, c);
      },
    );
  }
}
