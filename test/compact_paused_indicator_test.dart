import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'player_view_test.dart' show TestController, host, close;

void main() {
  for (final placement in LumioControlsPlacement.values) {
    testWidgets('compact paused indicator is bottom centered with $placement', (
      tester,
    ) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          duration: Duration(seconds: 20),
        );
      await tester.pumpWidget(
        host(
          controller,
          width: 600,
          configuration: LumioControlsConfiguration(
            compact: true,
            placement: placement,
          ),
        ),
      );
      final indicator = find.byKey(const ValueKey('lumio-compact-paused'));
      final surface = find.byKey(const ValueKey('lumio-gesture-surface'));
      expect(indicator, findsNothing);
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 350));
      expect(indicator, findsOneWidget);
      final bounds = tester.getRect(surface);
      final badge = tester.getRect(indicator);
      expect(badge.center.dx, closeTo(bounds.center.dx, .1));
      expect(bounds.bottom - badge.bottom, closeTo(16, .1));
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsOneWidget,
      );
      // The indicator is informational and does not consume surface taps.
      await tester.tapAt(badge.center);
      await tester.pump(const Duration(milliseconds: 350));
      expect(indicator, findsNothing);
      await tester.tap(surface);
      await tester.pump(const Duration(milliseconds: 350));
      expect(indicator, findsOneWidget);
      controller.value = controller.value.copyWith(playing: true);
      await tester.pump();
      expect(indicator, findsNothing);
      controller.value = controller.value.copyWith(
        playing: false,
        buffering: true,
      );
      await tester.pump();
      expect(indicator, findsNothing);
      controller.value = controller.value.copyWith(
        buffering: false,
        completed: true,
      );
      await tester.pump();
      expect(indicator, findsNothing);
      controller.value = controller.value.copyWith(
        completed: false,
        live: true,
      );
      await tester.pump();
      expect(indicator, findsNothing);
      await close(tester, controller);
    });
  }
}
