import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

import 'player_view_test.dart' show TestController, close;

void main() {
  for (final width in [320.0, 600.0, 900.0, 1400.0]) {
    testWidgets('fullscreen overlay has responsive safe padding at $width', (
      tester,
    ) async {
      tester.view.devicePixelRatio = 1;
      tester.view.physicalSize = Size(width, 500);
      addTearDown(tester.view.resetDevicePixelRatio);
      addTearDown(tester.view.resetPhysicalSize);
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          duration: Duration(minutes: 1),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: MediaQuery(
            data: MediaQueryData(
              size: Size(width, 500),
              padding: const EdgeInsets.only(left: 44, right: 22),
            ),
            child: Scaffold(
              body: LumioPlayerControls(
                controller: controller,
                isFullscreen: true,
                configuration: const LumioControlsConfiguration(
                  placement: LumioControlsPlacement.overlay,
                  layout: LumioControlsLayout.simplified,
                ),
              ),
            ),
          ),
        ),
      );
      final row = tester.getRect(
        find.byKey(const ValueKey('lumio-simplified-layout')),
      );
      final adaptive = (width * 0.03).clamp(20.0, 40.0);
      expect(row.left, 44 + adaptive);
      expect(row.right, width - 22 - adaptive);
      expect(find.byTooltip('Play'), findsOneWidget);
      expect(find.byTooltip('Playback speed'), findsOneWidget);
      expect(tester.takeException(), isNull);
      await close(tester, controller);
    });
  }

  for (final placement in LumioControlsPlacement.values) {
    testWidgets('inline $placement keeps the existing padding', (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          duration: Duration(minutes: 1),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LumioPlayerControls(
              controller: controller,
              configuration: LumioControlsConfiguration(
                placement: placement,
                layout: LumioControlsLayout.simplified,
              ),
            ),
          ),
        ),
      );
      final bounds = tester.getRect(find.byType(LumioPlayerControls));
      final row = tester.getRect(
        find.byKey(const ValueKey('lumio-simplified-layout')),
      );
      expect(row.left, bounds.left + 12);
      expect(row.right, bounds.right - 12);
      expect(tester.takeException(), isNull);
      await close(tester, controller);
    });
  }

  testWidgets('fullscreen compact progress still spans the entire width', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
      );
    await tester.pumpWidget(
      MaterialApp(
        home: MediaQuery(
          data: const MediaQueryData(
            size: Size(800, 600),
            padding: EdgeInsets.only(left: 44, right: 22),
          ),
          child: Scaffold(
            body: LumioPlayerControls(
              controller: controller,
              isFullscreen: true,
              compacted: true,
              configuration: const LumioControlsConfiguration(
                placement: LumioControlsPlacement.overlay,
              ),
            ),
          ),
        ),
      ),
    );
    final bounds = tester.getRect(find.byType(LumioPlayerControls));
    final progress = tester.getRect(
      find.byKey(const ValueKey('lumio-compact-progress')),
    );
    expect(progress, bounds);
    expect(progress.height, 4);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });
}
