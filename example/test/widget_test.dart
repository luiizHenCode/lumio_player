import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

void main() {
  test(
    'example can configure live playback without platform initialization',
    () {
      final controller = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          mode: LumioPlaybackMode.live,
        ),
      );
      expect(controller.configuration.mode, LumioPlaybackMode.live);
      expect(controller.value.initialized, isFalse);
      return controller.dispose();
    },
  );
}
