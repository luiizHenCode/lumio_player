import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  testWidgets('Android preview awaits native completion before next seek', (
    tester,
  ) async {
    debugDefaultTargetPlatformOverride = TargetPlatform.android;
    final native = NativeMock()..install();
    final controller = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: false,
      ),
    );
    final gate = Completer<Object?>();
    try {
      final open = controller.open(LumioSource.asset('test.mp4'));
      await tester.pump();
      await open;
      native.intercept = (call) async {
        if (call.method == 'seek' &&
            (call.arguments as Map)['waitForFrame'] == true) {
          return gate.future;
        }
        return native.respond(call);
      };
      final preview = controller.seekToPreview(const Duration(seconds: 3));
      final next = controller.seekTo(const Duration(seconds: 5));
      await tester.pump();
      expect(native.named('seek'), hasLength(1));
      expect(
        (native.named('seek').single.arguments as Map)['waitForFrame'],
        true,
      );
      expect(native.named('play'), isEmpty);
      gate.complete(null);
      await tester.pump();
      await preview;
      await next;
      expect(native.named('seek'), hasLength(2));
      expect(
        (native.named('seek').last.arguments as Map).containsKey(
          'waitForFrame',
        ),
        false,
      );
      expect(native.named('play'), isEmpty);
    } finally {
      if (!gate.isCompleted) gate.complete(null);
      final disposal = controller.dispose();
      await tester.pump();
      await disposal;
      native.uninstall();
      debugDefaultTargetPlatformOverride = null;
    }
  });
}
