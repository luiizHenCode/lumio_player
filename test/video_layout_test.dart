import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'player_view_test.dart' show TestController;

void main() {
  testWidgets(
    'default layout follows video ratio and explicit override is respected',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          size: Size(640, 480),
        );
      Widget host({double? ratio, BoxFit? fit}) => MaterialApp(
        home: Scaffold(
          body: Center(
            child: SizedBox(
              width: 300,
              child: LumioPlayerView(
                controller: controller,
                controls: false,
                aspectRatio: ratio,
                fit: fit,
              ),
            ),
          ),
        ),
      );
      await tester.pumpWidget(host());
      expect(
        tester.getSize(find.byKey(const ValueKey('lumio-gesture-surface'))),
        const Size(300, 225),
      );
      await tester.pumpWidget(host(ratio: 2, fit: BoxFit.cover));
      expect(
        tester.getSize(find.byKey(const ValueKey('lumio-gesture-surface'))),
        const Size(300, 150),
      );
      expect(
        tester.widget<FittedBox>(find.byType(FittedBox)).fit,
        BoxFit.cover,
      );
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  testWidgets(
    'expand fills finite available area and dynamic fit does not reopen media',
    (tester) async {
      final controller = TestController()
        ..value = const LumioPlayerState(
          initialized: true,
          size: Size(640, 360),
          position: Duration(seconds: 5),
        );
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              width: 300,
              height: 400,
              child: LumioPlayerView(
                controller: controller,
                controls: false,
                layout: LumioVideoLayout.expand,
              ),
            ),
          ),
        ),
      );
      expect(
        tester.getSize(find.byKey(const ValueKey('lumio-gesture-surface'))),
        const Size(300, 400),
      );
      await controller.setVideoFit(BoxFit.fill);
      await tester.pump();
      expect(tester.widget<FittedBox>(find.byType(FittedBox)).fit, BoxFit.fill);
      expect(controller.value.position, const Duration(seconds: 5));
      expect(controller.textureId, 42);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );

  testWidgets(
    'expand reports an actionable error in unbounded vertical scroll',
    (tester) async {
      final controller = TestController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SingleChildScrollView(
              child: LumioPlayerView(
                controller: controller,
                layout: LumioVideoLayout.expand,
              ),
            ),
          ),
        ),
      );
      final error = tester.takeException();
      expect(error, isA<FlutterError>());
      expect(error.toString(), contains('requires a finite height'));
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );
}
