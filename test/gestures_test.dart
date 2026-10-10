import 'dart:async';

import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/controls_configuration.dart';
import 'package:lumio_player/src/controller.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart' show LumioPlayerControls;

import 'controller_test.dart' show NativeMock;
import 'player_view_test.dart' show TestController, close, host;

const surfaceKey = ValueKey('lumio-gesture-surface');
const transformKey = ValueKey('lumio-surface-transform');

Future<void> doubleTap(WidgetTester tester, Offset point) async {
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 300));
}

class DelayedSpeedController extends TestController {
  final boost = Completer<void>();
  Future<void> _queue = Future.value();

  @override
  Future<void> setSpeed(double speed) {
    speeds.add(speed);
    final result = _queue.then((_) async {
      if (speed == 1) await boost.future;
      value = value.copyWith(speed: speed);
    });
    _queue = result;
    return result;
  }
}

Future<void> pinch(WidgetTester tester, {double distance = 120}) async {
  final center = tester.getCenter(find.byKey(surfaceKey));
  final first = await tester.startGesture(
    center - const Offset(20, 0),
    pointer: 1,
  );
  final second = await tester.startGesture(
    center + const Offset(20, 0),
    pointer: 2,
  );
  await tester.pump();
  await first.moveTo(center - const Offset(30, 0));
  await second.moveTo(center + const Offset(30, 0));
  await tester.pump();
  // Cross touch slop before applying the large scale delta.
  await first.moveTo(center - const Offset(60, 0));
  await second.moveTo(center + const Offset(60, 0));
  await tester.pump();
  await first.moveTo(center - Offset(distance, 0));
  await second.moveTo(center + Offset(distance, 0));
  await tester.pump();
  await first.up();
  await second.up();
  await tester.pump();
}

double zoom(WidgetTester tester) =>
    tester.widget<Transform>(find.byKey(transformKey)).transform.storage[0];

/// Uses the real controller queue and native event channel. The platform retains
/// its rate during auto-advance, just as Media3/AVQueuePlayer do.
class SpeedNativeMock extends NativeMock {
  double speed = 1;
  int? id;
  Completer<void>? boostGate;

  @override
  Future<Object?> respond(MethodCall call) async {
    final args = (call.arguments as Map?) ?? const {};
    if (call.method == 'open' || call.method == 'openPlaylist') {
      id = args['id'] as int;
      speed = (args['config']['speed'] as num).toDouble();
      if (call.method == 'openPlaylist') {
        await advance(args['index'] as int);
        return null;
      }
    } else if (call.method == 'speed') {
      speed = (args['speed'] as num).toDouble();
      if (speed == 1 && boostGate != null) await boostGate!.future;
    }
    return super.respond(call);
  }

  Future<void> advance(int index) => emit({
    'id': id,
    'type': 'state',
    'initialized': true,
    'playing': true,
    'buffering': false,
    'playlistIndex': index,
    'speed': speed,
    'positionMs': 0,
  });
}

void main() {
  final compactControls = find.byKey(const ValueKey('lumio-compact-controls'));
  final progress = find.byKey(const ValueKey('lumio-progress'));

  for (final placement in LumioControlsPlacement.values) {
    for (final liveOrigin in ['state', 'mode', 'layout']) {
      testWidgets(
        '$placement live from $liveOrigin toggles compact without double-tap delay',
        (tester) async {
          final controller =
              TestController(
                  configuration: LumioPlayerConfiguration(
                    mode: liveOrigin == 'mode'
                        ? LumioPlaybackMode.live
                        : LumioPlaybackMode.video,
                  ),
                )
                ..value = LumioPlayerState(
                  initialized: true,
                  playing: true,
                  live: liveOrigin == 'state',
                );
          await tester.pumpWidget(
            host(
              controller,
              width: 390,
              configuration: LumioControlsConfiguration(
                placement: placement,
                layout: liveOrigin == 'layout'
                    ? LumioControlsLayout.live
                    : LumioControlsLayout.automatic,
                compact: true,
                enableZoom: true,
              ),
            ),
          );
          final surface = find.byKey(surfaceKey);
          final detector = tester.widget<GestureDetector>(surface);
          expect(detector.onDoubleTapDown, isNull);
          expect(detector.onDoubleTap, isNull);
          expect(detector.onLongPressStart, isNull);
          expect(detector.onLongPressEnd, isNull);
          final point = tester.getRect(surface).topCenter + const Offset(0, 24);
          await tester.tapAt(point);
          await tester.pump();
          expect(
            tester
                .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
                .compacted,
            true,
          );
          await tester.tapAt(
            tester.getRect(surface).topCenter + const Offset(0, 24),
          );
          await tester.pump();
          expect(
            tester
                .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
                .compacted,
            false,
          );
          expect(controller.speeds, isEmpty);
          expect(controller.sought, isNull);
          await close(tester, controller);
        },
      );
    }
    testWidgets('$placement default compact deadline is exactly five seconds', (
      tester,
    ) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true, playing: true);
      await tester.pumpWidget(
        host(
          controller,
          configuration: LumioControlsConfiguration(
            placement: placement,
            compact: true,
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 4999));
      expect(progress, findsOneWidget);
      expect(compactControls, findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(progress, findsNothing);
      expect(compactControls, findsOneWidget);
      await close(tester, controller);
    });

    testWidgets(
      '$placement single tap toggles visible compact visible and restarts deadline',
      (tester) async {
        final controller = TestController()
          ..value = const LumioPlayerState(initialized: true, playing: true);
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(
              placement: placement,
              compact: true,
            ),
          ),
        );
        expect(progress, findsOneWidget);
        await tester.tapAt(
          tester.getTopLeft(find.byKey(surfaceKey)) + const Offset(30, 20),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(compactControls, findsOneWidget);
        await tester.tapAt(
          tester.getTopLeft(find.byKey(surfaceKey)) + const Offset(30, 20),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(progress, findsOneWidget);
        expect(compactControls, findsNothing);
        // onTap resolves 300 ms after pointer-up; 50 ms of its new timer elapsed.
        await tester.pump(const Duration(milliseconds: 4949));
        expect(progress, findsOneWidget);
        await tester.pump(const Duration(milliseconds: 1));
        expect(compactControls, findsOneWidget);
        await close(tester, controller);
      },
    );

    testWidgets('$placement compact disabled never toggles or auto-hides', (
      tester,
    ) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true, playing: true);
      await tester.pumpWidget(
        host(
          controller,
          configuration: LumioControlsConfiguration(placement: placement),
        ),
      );
      for (var i = 0; i < 2; i++) {
        await tester.tapAt(
          tester.getTopLeft(find.byKey(surfaceKey)) + const Offset(30, 20),
        );
        await tester.pump(const Duration(milliseconds: 350));
        expect(progress, findsOneWidget);
        expect(compactControls, findsNothing);
      }
      await tester.pump(const Duration(seconds: 6));
      expect(progress, findsOneWidget);
      await close(tester, controller);
    });

    testWidgets('$placement controls clicks do not toggle the surface', (
      tester,
    ) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true, playing: true);
      await tester.pumpWidget(
        host(
          controller,
          configuration: LumioControlsConfiguration(
            placement: placement,
            compact: true,
          ),
        ),
      );
      await tester.tap(find.byTooltip('Mute'));
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.value.volume, 0);
      expect(progress, findsOneWidget);
      expect(compactControls, findsNothing);
      expect(controller.sought, isNull);
      expect(controller.speeds, isEmpty);
      await tester.pump(const Duration(seconds: 5));
      expect(compactControls, findsOneWidget);
      await tester.tap(compactControls);
      await tester.pump(const Duration(milliseconds: 350));
      expect(progress, findsOneWidget);
      expect(compactControls, findsNothing);
      await close(tester, controller);
    });

    testWidgets(
      '$placement double tap seeks without single tap compact toggle',
      (tester) async {
        final controller = TestController()
          ..value = const LumioPlayerState(
            initialized: true,
            playing: true,
            duration: Duration(minutes: 1),
          );
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(
              placement: placement,
              compact: true,
            ),
          ),
        );
        for (final initiallyHidden in [false, true]) {
          if (initiallyHidden) {
            await tester.pump(const Duration(seconds: 5));
            expect(compactControls, findsOneWidget);
          }
          await doubleTap(
            tester,
            tester.getTopRight(find.byKey(surfaceKey)) + const Offset(-30, 20),
          );
          expect(controller.sought, const Duration(seconds: 10));
          expect(progress, findsOneWidget);
          expect(compactControls, findsNothing);
        }
        await close(tester, controller);
      },
    );

    testWidgets('$placement hold and pinch reveal without compact toggle', (
      tester,
    ) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true, playing: true);
      await tester.pumpWidget(
        host(
          controller,
          width: 600,
          configuration: LumioControlsConfiguration(
            placement: placement,
            compact: true,
            enableZoom: true,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(compactControls, findsOneWidget);
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(surfaceKey)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      expect(controller.value.speed, 2);
      await gesture.up();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.value.speed, 1);
      expect(progress, findsOneWidget);
      expect(compactControls, findsNothing);
      await pinch(tester);
      await tester.pump(const Duration(milliseconds: 350));
      expect(zoom(tester), greaterThan(1));
      expect(progress, findsOneWidget);
      expect(compactControls, findsNothing);
      await close(tester, controller);
    });
  }

  testWidgets(
    'ready paused media toggles and stays hidden across paused state updates',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true);
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(compact: true),
        ),
      );
      await tester.pump(const Duration(seconds: 6));
      expect(progress, findsOneWidget);
      await tester.tap(find.byKey(surfaceKey));
      await tester.pump(const Duration(milliseconds: 350));
      expect(compactControls, findsOneWidget);
      await tester.pump(const Duration(seconds: 6));
      expect(compactControls, findsOneWidget);
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 1),
      );
      await tester.pump();
      expect(compactControls, findsOneWidget);
      await tester.tap(find.byKey(surfaceKey));
      await tester.pump(const Duration(milliseconds: 350));
      expect(progress, findsOneWidget);
      await tester.tap(find.byKey(surfaceKey));
      await tester.pump(const Duration(milliseconds: 350));
      expect(compactControls, findsOneWidget);
      controller.value = controller.value.copyWith(playing: true);
      await tester.pump();
      expect(compactControls, findsOneWidget);
      await close(tester, controller);
    },
  );

  for (final state in [
    const LumioPlayerState(),
    const LumioPlayerState(initialized: true, transitioning: true),
    const LumioPlayerState(initialized: true, playing: true, buffering: true),
    const LumioPlayerState(
      initialized: true,
      playing: true,
      error: LumioPlayerError(code: 'test', message: 'Failure'),
    ),
  ]) {
    testWidgets('unready or buffering media remains visible on tap: $state', (
      tester,
    ) async {
      final controller = TestController()..value = state;
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(compact: true),
        ),
      );
      await tester.tap(find.byKey(surfaceKey));
      await tester.pump(const Duration(milliseconds: 350));
      await tester.pump(const Duration(seconds: 6));
      expect(compactControls, findsNothing);
      expect(progress, findsOneWidget);
      await close(tester, controller);
    });
  }

  testWidgets('buffering preserves compact controls and errors reveal them', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true, playing: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(compact: true),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    expect(compactControls, findsOneWidget);
    controller.value = controller.value.copyWith(buffering: true);
    await tester.pump(const Duration(seconds: 6));
    expect(compactControls, findsOneWidget);
    controller.value = controller.value.copyWith(buffering: false);
    await tester.pump(const Duration(seconds: 5));
    expect(compactControls, findsOneWidget);
    controller.value = controller.value.copyWith(
      error: const LumioPlayerError(code: 'test', message: 'Failure'),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(compactControls, findsNothing);
    expect(find.byTooltip('Retry'), findsOneWidget);
    await close(tester, controller);
  });

  final holdOverlay = find.byKey(const ValueKey('lumio-hold-speed-label'));

  for (final (speed, target) in [
    (1.0, 2.0),
    (2.0, 1.0),
    (3.0, 1.0),
    (4.0, 1.0),
  ]) {
    for (final cancel in [false, true]) {
      testWidgets('hold $speed → $target restores on cancel=$cancel', (
        tester,
      ) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true, speed: speed);
        await tester.pumpWidget(host(controller));
        expect(holdOverlay, findsNothing);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(surfaceKey)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
        expect(controller.speeds, [target]);
        expect(controller.value.speed, target);
        expect(holdOverlay, findsOneWidget);
        expect(tester.widget<Text>(holdOverlay).data, '${target.toInt()}x');
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump();
        expect(controller.speeds, [target, speed]);
        expect(controller.value.speed, speed);
        expect(holdOverlay, findsNothing);
        await close(tester, controller);
      });
    }
  }

  for (final speed in [1.5, .75]) {
    for (final cancel in [false, true]) {
      testWidgets('custom $speed does not start hold on cancel=$cancel', (
        tester,
      ) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true, speed: speed);
        await tester.pumpWidget(host(controller));
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(surfaceKey)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
        expect(controller.speeds, isEmpty);
        expect(controller.value.speed, speed);
        expect(holdOverlay, findsNothing);
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump();
        expect(controller.speeds, isEmpty);
        expect(controller.value.speed, speed);
        expect(holdOverlay, findsNothing);
        await close(tester, controller);
      });
    }
  }

  for (final speed in [1.0, 2.0, 3.0, 4.0, 1.5, .75]) {
    for (final cancel in [false, true]) {
      testWidgets('custom holdSpeed 3 from $speed on cancel=$cancel', (
        tester,
      ) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true, speed: speed);
        await tester.pumpWidget(
          host(
            controller,
            configuration: const LumioControlsConfiguration(holdSpeed: 3),
          ),
        );
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(surfaceKey)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
        final eligible = speed == 1 || speed >= 2;
        final target = speed == 1 ? 3.0 : 1.0;
        expect(controller.speeds, eligible ? [target] : isEmpty);
        expect(controller.value.speed, eligible ? target : speed);
        expect(holdOverlay, eligible ? findsOneWidget : findsNothing);
        if (eligible) {
          expect(tester.widget<Text>(holdOverlay).data, '${target.toInt()}x');
        }
        if (cancel) {
          await gesture.cancel();
        } else {
          await gesture.up();
        }
        await tester.pump();
        expect(controller.speeds, eligible ? [target, speed] : isEmpty);
        expect(controller.value.speed, speed);
        expect(holdOverlay, findsNothing);
        await close(tester, controller);
      });
    }
  }

  for (final delayedBoost in [false, true]) {
    testWidgets(
      'real native auto-advance restores persistent hold rate (delayed=$delayedBoost)',
      (tester) async {
        final native = SpeedNativeMock()..install();
        addTearDown(native.uninstall);
        final controller = LumioPlayerController(
          configuration: const LumioPlayerConfiguration(
            engine: LumioPlaybackEngine.native,
            speed: 3,
          ),
        );
        await tester.pumpWidget(host(controller));
        await tester.runAsync(
          () => controller.openPlaylist(
            LumioPlaylist([
              LumioPlaylistItem(
                source: LumioSource.asset('first.mp4'),
                title: 'First',
              ),
              LumioPlaylistItem(
                source: LumioSource.asset('second.mp4'),
                title: 'Second',
              ),
            ]),
          ),
        );
        await tester.pump();
        expect(find.text('First'), findsOneWidget);
        if (delayedBoost) native.boostGate = Completer<void>();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(surfaceKey)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(controller.value.playing, true);
        expect(controller.value.speed, delayedBoost ? 3 : 1);
        expect(native.speed, 1);
        await tester.runAsync(() async {
          await native.advance(1);
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(controller.playlistIndex, 1);
        expect(find.text('Second'), findsOneWidget);
        await gesture.up();
        native.boostGate?.complete();
        await tester.runAsync(() async {
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(controller.value.speed, 3);
        expect(native.speed, 3);
        expect(
          native.named('speed').map((call) => (call.arguments as Map)['speed']),
          [1, 3],
        );
        // Reopening an engine/source must also use the restored controller-global rate.
        await tester.runAsync(
          () => controller.open(LumioSource.asset('third.mp4')),
        );
        await tester.pump();
        expect(
          (native.named('open').last.arguments as Map)['config']['speed'],
          3,
        );
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 350));
        await tester.runAsync(controller.dispose);
      },
    );
  }

  for (final delayedBoost in [false, true]) {
    testWidgets(
      'real native revision preserves explicit 1x after hold (delayed=$delayedBoost)',
      (tester) async {
        final native = SpeedNativeMock()..install();
        addTearDown(native.uninstall);
        final controller = LumioPlayerController(
          configuration: const LumioPlayerConfiguration(
            engine: LumioPlaybackEngine.native,
            speed: 3,
          ),
        );
        await tester.pumpWidget(host(controller));
        await tester.runAsync(
          () => controller.openPlaylist(
            LumioPlaylist([
              LumioPlaylistItem(source: LumioSource.asset('first.mp4')),
            ]),
          ),
        );
        await tester.pump();
        if (delayedBoost) native.boostGate = Completer<void>();
        final gesture = await tester.startGesture(
          tester.getCenter(find.byKey(surfaceKey)),
        );
        await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
        await tester.runAsync(() => Future<void>.delayed(Duration.zero));
        await tester.pump();
        expect(native.speed, 1);
        expect(controller.value.speed, delayedBoost ? 3 : 1);

        final holdRevision = controller.speedRevision;
        late Future<void> explicitRate;
        await tester.runAsync(() async {
          explicitRate = controller.setSpeed(1);

          expect(controller.speedRevision, greaterThan(holdRevision));
          await Future<void>.delayed(Duration.zero);
        });
        await gesture.up();
        native.boostGate?.complete();
        await tester.runAsync(() async {
          await explicitRate;

          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        expect(controller.value.speed, 1);
        expect(native.speed, 1);
        expect(
          native.named('speed').map((call) => (call.arguments as Map)['speed']),
          [1, 1],
        );
        expect(holdOverlay, findsNothing);
        await tester.pumpWidget(const SizedBox.shrink());
        await tester.pump(const Duration(milliseconds: 350));
        late Future<void> disposal;
        await tester.runAsync(() async {
          disposal = controller.dispose();
          await Future<void>.delayed(Duration.zero);
        });
        await tester.pump();
        await tester.runAsync(() => disposal);
      },
    );
  }

  testWidgets(
    'explicit developer rate cancels hold without reverting that rate',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          playing: true,
          speed: 4,
        );
      await tester.pumpWidget(host(controller));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(surfaceKey)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await controller.setSpeed(3);
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(controller.speeds, [1, 3]);
      expect(controller.value.speed, 3);
      await close(tester, controller);
    },
  );

  testWidgets(
    'swapping controllers restores only the controller that owns the hold',
    (tester) async {
      final first = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          playing: true,
          speed: 4,
        );
      final second = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          playing: true,
          speed: 3,
        );
      await tester.pumpWidget(host(first));
      final gesture = await tester.startGesture(
        tester.getCenter(find.byKey(surfaceKey)),
      );
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      await tester.pumpWidget(host(second));
      await tester.pump();
      await gesture.up();
      await tester.pump();
      expect(first.speeds, [1, 4]);
      expect(first.value.speed, 4);
      expect(second.value.speed, 3);
      expect(second.speeds, isEmpty);
      await close(tester, first);
      await close(tester, second);
    },
  );
  testWidgets('double tap seeks by viewport half and clamps both ends', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(seconds: 30),
        position: Duration(seconds: 5),
      );
    await tester.pumpWidget(host(controller));
    final rect = tester.getRect(find.byKey(surfaceKey));
    await doubleTap(tester, Offset(rect.left + 25, rect.center.dy));
    expect(controller.sought, Duration.zero);
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 25),
    );
    await tester.pump();
    await doubleTap(tester, Offset(rect.right - 25, rect.center.dy));
    expect(controller.sought, const Duration(seconds: 30));
    await close(tester, controller);
  });

  testWidgets('custom double tap interval; live, idle and error never seek', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
      );
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          seekInterval: Duration(seconds: 3),
        ),
      ),
    );
    final point =
        tester.getTopRight(find.byKey(surfaceKey)) + const Offset(-20, 30);
    await doubleTap(tester, point);
    expect(controller.sought, const Duration(seconds: 3));
    for (final state in [
      const LumioPlayerState(
        live: true,
        initialized: true,
        duration: Duration(minutes: 1),
      ),
      const LumioPlayerState(duration: Duration(minutes: 1)),
      const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
        error: LumioPlayerError(code: 'test', message: 'Failure'),
      ),
    ]) {
      controller.sought = null;
      controller.value = state;
      await tester.pump();
      await doubleTap(tester, point);
      expect(controller.sought, isNull);
    }
    await close(tester, controller);
  });

  testWidgets(
    'master switches and individual gesture switches disable commands',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          duration: Duration(minutes: 1),
        );
      for (final configuration in [
        const LumioControlsConfiguration(enabled: false, enableZoom: true),
        const LumioControlsConfiguration(
          doubleTapSeek: false,
          holdToSpeed: false,
        ),
      ]) {
        await tester.pumpWidget(host(controller, configuration: configuration));
        final point =
            tester.getCenter(find.byKey(surfaceKey)) + const Offset(50, 0);
        await doubleTap(tester, point);
        await tester.longPressAt(point);
        await tester.pump();
        expect(controller.sought, isNull);
        expect(controller.speeds, isEmpty);
        await pinch(tester);
        expect(zoom(tester), 1);
      }
      await tester.pumpWidget(
        host(
          controller,
          controls: false,
          configuration: const LumioControlsConfiguration(enableZoom: true),
        ),
      );
      await tester.longPress(find.byKey(surfaceKey));
      await tester.pump();
      expect(controller.speeds, isEmpty);
      await pinch(tester);
      expect(zoom(tester), 1);
      await close(tester, controller);
    },
  );

  testWidgets('hold restores exact speed after moving and release', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true, speed: 3);
    await tester.pumpWidget(host(controller));
    final point = tester.getCenter(find.byKey(surfaceKey));
    final gesture = await tester.startGesture(point);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(controller.value.speed, 1);
    await gesture.moveBy(const Offset(50, 0));
    await gesture.up();
    await tester.pump();
    expect(controller.speeds, [1, 3]);
    expect(controller.value.speed, 3);
    await close(tester, controller);
  });

  testWidgets('release before boost acknowledgement still queues restoration', (
    tester,
  ) async {
    final controller = DelayedSpeedController()
      ..value = const LumioPlayerState(initialized: true, speed: 4);
    await tester.pumpWidget(host(controller));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(controller.speeds, [1]);
    expect(controller.value.speed, 4);
    await gesture.up();
    await tester.pump();
    expect(controller.speeds, [1]);
    controller.boost.complete();
    await tester.pump();
    expect(controller.speeds, [1, 4]);
    expect(controller.value.speed, 4);
    await close(tester, controller);
  });

  testWidgets('pointer cancellation and disposal restore hold speed', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true, speed: 3);
    await tester.pumpWidget(host(controller));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(controller.speeds, [1]);
    await gesture.cancel();
    await tester.pump();
    expect(controller.speeds, [1, 3]);
    expect(controller.value.speed, 3);
    final second = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    expect(controller.speeds, [1, 3, 1]);
    await tester.pumpWidget(const SizedBox.shrink());
    await tester.pump();
    expect(controller.speeds, [1, 3, 1, 3]);
    expect(controller.value.speed, 3);
    await second.cancel();
    await close(tester, controller);
  });

  testWidgets('source change cancels hold without restoring onto new item', (
    tester,
  ) async {
    final controller = TestController()
      ..testSource = LumioSource.asset('first.mp4')
      ..value = const LumioPlayerState(initialized: true, speed: 3);
    await tester.pumpWidget(host(controller));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    controller.testSource = LumioSource.asset('second.mp4');
    controller.value = controller.value.copyWith(speed: 2);
    await tester.pump();
    await gesture.up();
    await tester.pump();
    expect(controller.speeds, [1]);
    expect(controller.value.speed, 2);
    await close(tester, controller);
  });

  testWidgets('engine change restores hold and live cannot begin hold', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true, speed: 3);
    await tester.pumpWidget(host(controller));
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    controller.value = controller.value.copyWith(
      engine: LumioPlaybackEngine.webview,
    );
    await tester.pump();
    expect(controller.speeds, [1, 3]);
    expect(controller.value.speed, 3);
    await gesture.up();
    controller.speeds.clear();
    controller.value = controller.value.copyWith(live: true);
    await tester.pump();
    await tester.longPress(find.byKey(surfaceKey));
    await tester.pump();
    expect(controller.speeds, isEmpty);
    await close(tester, controller);
  });

  testWidgets(
    'pinch is opt-in, clamped, reset on source change; no hold during pinch',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(initialized: true);
      await tester.pumpWidget(host(controller));
      await pinch(tester);
      expect(zoom(tester), 1);
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(
            enableZoom: true,
            maxZoom: 3,
          ),
        ),
      );
      await pinch(tester, distance: 300);
      expect(zoom(tester), 3);
      final panGesture = await tester.startGesture(
        tester.getCenter(find.byKey(surfaceKey)),
      );
      await panGesture.moveBy(const Offset(20, 0));
      await tester.pump();
      await panGesture.moveBy(const Offset(1000, 1000));
      await tester.pump();
      final matrix = tester
          .widget<Transform>(find.byKey(transformKey))
          .transform;
      final bounds = tester.getSize(find.byKey(surfaceKey));
      expect(matrix.storage[12].abs(), lessThanOrEqualTo(bounds.width));
      expect(matrix.storage[13].abs(), lessThanOrEqualTo(bounds.height));
      await panGesture.up();
      await tester.pump();
      expect(controller.speeds, isEmpty);
      controller.testSource = LumioSource.asset('next.mp4');
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 1),
      );
      await tester.pump();
      expect(zoom(tester), 1);
      await close(tester, controller);
    },
  );

  testWidgets('second pointer cancels active hold', (tester) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(enableZoom: true),
      ),
    );
    final point = tester.getCenter(find.byKey(surfaceKey));
    final first = await tester.startGesture(point, pointer: 1);
    await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
    final second = await tester.startGesture(
      point + const Offset(25, 0),
      pointer: 2,
    );
    await tester.pump();
    expect(controller.value.speed, 1);
    await second.up();
    await first.up();
    await close(tester, controller);
  });

  testWidgets(
    'compact deadline survives position events, tap reveals and pause stays visible',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          playing: true,
          duration: Duration(minutes: 1),
        );
      await tester.pumpWidget(
        host(
          controller,
          title: 'Broadcast',
          configuration: const LumioControlsConfiguration(compact: true),
        ),
      );
      expect(find.byTooltip('Pause'), findsOneWidget);
      await tester.pump(const Duration(seconds: 1));
      controller.value = controller.value.copyWith(
        position: const Duration(seconds: 1),
      );
      await tester.pump(const Duration(seconds: 4));
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsOneWidget,
      );
      expect(find.byTooltip('Pause'), findsNothing);
      expect(find.text('Broadcast'), findsNothing);
      expect(find.byType(Texture), findsOneWidget);
      final element = tester.element(find.byType(Texture));
      await tester.tap(find.byKey(surfaceKey));
      await tester.pump(const Duration(milliseconds: 350));
      expect(find.byTooltip('Pause'), findsOneWidget);
      expect(tester.element(find.byType(Texture)), same(element));
      controller.value = controller.value.copyWith(playing: false);
      await tester.pump(const Duration(seconds: 6));
      expect(find.byTooltip('Play'), findsOneWidget);
      await close(tester, controller);
    },
  );

  testWidgets('compact remains expanded while holding or showing an error', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true, playing: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(compact: true),
      ),
    );
    final gesture = await tester.startGesture(
      tester.getCenter(find.byKey(surfaceKey)),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(find.byTooltip('Pause'), findsOneWidget);
    await gesture.up();
    controller.value = controller.value.copyWith(
      error: const LumioPlayerError(code: 'test', message: 'Failure'),
    );
    await tester.pump(const Duration(seconds: 6));
    expect(find.byTooltip('Retry'), findsOneWidget);
    expect(find.byKey(const ValueKey('lumio-compact-progress')), findsNothing);
    await close(tester, controller);
  });
}
