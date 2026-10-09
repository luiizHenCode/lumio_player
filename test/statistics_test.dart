import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

class StatisticsController extends LumioPlayerController {
  int calls = 0;
  bool fail = false;
  Completer<Map<String, dynamic>>? pending;
  @override
  Future<Map<String, dynamic>> diagnostics() async {
    ++calls;
    if (fail) throw StateError('secret should never be shown');
    if (pending != null) return pending!.future;
    return {
      'engine': 'native',
      'requestedEngine': 'automatic',
      'fallbackUsed': false,
      'playback': {'width': 1920, 'height': 1080, 'bufferAheadMs': 2000},
      'native': {
        'model': 'Test phone',
        'manufacturer': 'Test',
        'player': {
          'videoMimeType': 'video/avc',
          'videoDecoderName': 'test.decoder',
          'frameRate': 30,
        },
      },
    };
  }
}

void main() {
  testWidgets(
    'statistics display codec, device, unavailable metrics and stop polling on removal',
    (tester) async {
      final controller = StatisticsController();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: SizedBox(
              height: 600,
              child: LumioStatisticsView(controller: controller),
            ),
          ),
        ),
      );
      await tester.pump();
      expect(find.text('Codec vídeo: video/avc'), findsOneWidget);
      expect(find.text('Dispositivo: Test phone'), findsOneWidget);
      expect(find.text('Decoder áudio: —'), findsOneWidget);
      expect(controller.calls, 1);
      await tester.pump(const Duration(seconds: 2));
      expect(controller.calls, 2);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pump(const Duration(seconds: 4));
      expect(controller.calls, 2);
      await controller.dispose();
    },
  );

  testWidgets(
    'polling does not overlap and pending result is ignored after removal',
    (tester) async {
      final controller = StatisticsController()..pending = Completer();
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LumioStatisticsView(controller: controller)),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(controller.calls, 1);
      await tester.pumpWidget(const SizedBox.shrink());
      controller.pending!.complete({});
      await tester.pump();
      expect(tester.takeException(), isNull);
      await controller.dispose();
    },
  );

  testWidgets(
    'statistics action is opt-in and unavailable diagnostic errors are safe',
    (tester) async {
      final controller = StatisticsController()..fail = true;
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LumioPlayerControls(controller: controller)),
        ),
      );
      expect(find.byTooltip('Estatísticas para nerds'), findsNothing);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(
            body: LumioPlayerControls(
              controller: controller,
              configuration: const LumioControlsConfiguration(
                showStatistics: true,
              ),
            ),
          ),
        ),
      );
      await tester.tap(find.byTooltip('Estatísticas para nerds'));
      await tester.pumpAndSettle();
      expect(find.textContaining('Não foi possível atualizar'), findsOneWidget);
      expect(find.textContaining('secret'), findsNothing);
      await tester.pumpWidget(const SizedBox.shrink());
      await controller.dispose();
    },
  );
}
