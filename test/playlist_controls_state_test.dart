import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'player_view_test.dart' show TestController, host, close;

void main() {
  for (final compacted in [false, true]) {
    for (final placement in LumioControlsPlacement.values) {
      testWidgets('playlist preserves compact=$compacted with $placement', (
        tester,
      ) async {
        final first = LumioSource.asset('first.mp4');
        final second = LumioSource.asset('second.mp4');
        final controller = TestController()
          ..testSource = first
          ..testPlaylist = LumioPlaylist([
            LumioPlaylistItem(source: first),
            LumioPlaylistItem(source: second),
          ])
          ..value = LumioPlayerState(
            initialized: true,
            playing: true,
            duration: Duration(seconds: 10),
          );
        final config = LumioControlsConfiguration(
          compact: true,
          compactDelay: const Duration(seconds: 5),
          placement: placement,
        );
        await tester.pumpWidget(host(controller, configuration: config));
        if (compacted) await tester.pump(const Duration(seconds: 5));
        bool hidden() => tester
            .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
            .compacted;
        expect(hidden(), compacted);

        // WebView emits completion before opening the next source; native
        // playlists can emit a buffering/paused state during index advancement.
        controller.value = controller.value.copyWith(
          playing: false,
          completed: true,
        );
        await tester.pump();
        expect(hidden(), compacted);
        controller.testPlaylistIndex = 1;
        controller.testSource = second;
        controller.value = controller.value.copyWith(
          initialized: false,
          completed: false,
          transitioning: true,
          buffering: true,
        );
        await tester.pump();
        expect(hidden(), compacted);
        // Host rebuilds must not reset presentation either.
        await tester.pumpWidget(host(controller, configuration: config));
        expect(hidden(), compacted);
        controller.value = controller.value.copyWith(
          initialized: true,
          transitioning: false,
          buffering: false,
        );
        await tester.pump();
        expect(hidden(), compacted);
        controller.value = controller.value.copyWith(playing: true);
        await tester.pump();
        expect(hidden(), compacted);
        // Normal inactivity compaction remains enabled for expanded controls.
        await tester.pump(const Duration(seconds: 5));
        expect(hidden(), true);
        await close(tester, controller);
      });
    }
  }

  testWidgets('direct native index change preserves compact controls', (
    tester,
  ) async {
    final controller = TestController()
      ..testPlaylist = LumioPlaylist([
        LumioPlaylistItem(source: LumioSource.asset('first.mp4')),
        LumioPlaylistItem(source: LumioSource.asset('second.mp4')),
      ])
      ..value = LumioPlayerState(initialized: true, playing: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(compact: true),
      ),
    );
    await tester.pump(const Duration(seconds: 5));
    controller.testPlaylistIndex = 1;
    controller.value = controller.value.copyWith(
      playing: false,
      buffering: true,
    );
    await tester.pump();
    expect(
      tester
          .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
          .compacted,
      true,
    );
    controller.value = controller.value.copyWith(
      playing: true,
      buffering: false,
    );
    await tester.pump();
    expect(
      tester
          .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
          .compacted,
      true,
    );
    await close(tester, controller);
  });
}
