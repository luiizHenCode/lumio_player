import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/models.dart';

void main() {
  test('audio defaults preserve host and disable background playback', () {
    const config = LumioPlayerConfiguration();
    expect(config.audioPolicy, LumioAudioPolicy.preserveHost);
    expect(config.allowBackgroundPlayback, isFalse);
    expect(config.toMap()['audioPolicy'], 'preserveHost');
    expect(config.toMap()['allowBackgroundPlayback'], isFalse);
    expect(config.validate, returnsNormally);
  });

  test(
    'audio policy and background opt-in serialize independently of mode',
    () {
      for (final mode in LumioPlaybackMode.values) {
        for (final policy in LumioAudioPolicy.values) {
          for (final background in [false, true]) {
            final config = LumioPlayerConfiguration(
              mode: mode,
              audioPolicy: policy,
              allowBackgroundPlayback: background,
            );
            expect(config.toMap()['audioPolicy'], policy.name);
            expect(config.toMap()['allowBackgroundPlayback'], background);
            expect(config.validate, returnsNormally);
          }
        }
      }
    },
  );
}
