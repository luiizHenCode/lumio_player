import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

import 'player_view_test.dart' show TestController, close, host;

class LoadingController extends TestController {
  LoadingController({super.configuration});
  bool recoveryPending = false;
  @override
  bool get isRecovering => recoveryPending;
}

final central = find.byKey(const ValueKey('lumio-loading-indicator'));
final badge = find.byKey(const ValueKey('lumio-loading-badge'));
const delay = Duration(milliseconds: 700);

LumioPlayerState video({bool frame = true, bool buffering = false}) =>
    LumioPlayerState(
      initialized: true,
      playing: true,
      firstFrameSupported: true,
      hasRenderedFirstFrame: frame,
      buffering: buffering,
    );

void main() {
  test('visual delay accepts zero, rejects negative even with loader off', () {
    const LumioControlsConfiguration(
      bufferingIndicatorDelay: Duration.zero,
    ).validate();
    expect(
      () => const LumioControlsConfiguration(
        showLoader: false,
        bufferingIndicatorDelay: Duration(microseconds: -1),
      ).validate(),
      throwsArgumentError,
    );
  });

  testWidgets(
    'opening is immediate; supported video waits for frame evidence',
    (tester) async {
      final c = LoadingController();
      await tester.pumpWidget(host(c, controls: false));
      expect(central, findsOneWidget);
      c.value = video(frame: false);
      await tester.pump();
      await tester.pump(delay);
      expect(central, findsOneWidget);
      expect(badge, findsNothing);
      c.value = video();
      await tester.pump();
      expect(central, findsNothing);
      expect(badge, findsNothing);
      await close(tester, c);
    },
  );

  testWidgets('paused readiness does not invent playback history', (
    tester,
  ) async {
    final c = LoadingController(
      configuration: const LumioPlayerConfiguration(autoPlay: false),
    )..value = LumioPlayerState(initialized: true, firstFrameSupported: true);
    await tester.pumpWidget(host(c, controls: false));
    expect(central, findsNothing);
    c.value = c.value.copyWith(buffering: true);
    await tester.pump();
    expect(central, findsOneWidget);
    expect(badge, findsNothing);
    await close(tester, c);
  });

  testWidgets(
    'short buffering cancels; polling preserves the visual deadline',
    (tester) async {
      final c = LoadingController()..value = video();
      await tester.pumpWidget(
        host(c, configuration: const LumioControlsConfiguration(compact: true)),
      );
      await tester.pump(const Duration(seconds: 5));
      expect(
        find.byKey(const ValueKey('lumio-compact-controls')),
        findsOneWidget,
      );
      c.value = video(buffering: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      expect(badge, findsNothing);
      c.value = video();
      await tester.pump();
      await tester.pump(delay);
      expect(badge, findsNothing);

      c.value = video(buffering: true);
      await tester.pump();
      for (var i = 0; i < 6; i++) {
        await tester.pump(const Duration(milliseconds: 100));
        c.value = c.value.copyWith(position: Duration(seconds: i));
        await tester.pump();
      }
      expect(badge, findsNothing);
      await tester.pump(const Duration(milliseconds: 100));
      expect(badge, findsOneWidget);
      expect(central, findsNothing);
      expect(find.text('Carregando…'), findsOneWidget);
      final spinner = find.descendant(
        of: badge,
        matching: find.byType(CircularProgressIndicator),
      );
      expect(tester.getSize(spinner), const Size(14, 14));
      final media = tester.getRect(
        find.byKey(const ValueKey('lumio-gesture-surface')),
      );
      expect(tester.getRect(badge).top, media.top + 12);
      expect(
        find.ancestor(
          of: badge,
          matching: find.byWidgetPredicate(
            (widget) => widget is IgnorePointer && widget.ignoring,
          ),
        ),
        findsOneWidget,
      );
      expect(find.byType(Texture), findsOneWidget);
      // The badge does not intercept the surface's presentation gesture.
      await tester.tapAt(tester.getCenter(badge));
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('lumio-compact-controls')),
        findsNothing,
      );
      c.value = video();
      await tester.pump();
      expect(badge, findsNothing);
      await close(tester, c);
    },
  );

  for (final audio in [false, true]) {
    testWidgets(
      '${audio ? 'audio' : 'legacy video'} observes initialized playing',
      (tester) async {
        final c =
            LoadingController(
                configuration: LumioPlayerConfiguration(
                  mode: audio
                      ? LumioPlaybackMode.audio
                      : LumioPlaybackMode.video,
                ),
              )
              ..value = LumioPlayerState(
                initialized: true,
                playing: true,
                firstFrameSupported: audio,
              );
        await tester.pumpWidget(host(c, controls: false));
        c.value = c.value.copyWith(buffering: true);
        await tester.pump();
        expect(central, findsNothing);
        expect(badge, findsNothing);
        await tester.pump(delay);
        expect(badge, findsOneWidget);
        await close(tester, c);
      },
    );
  }

  testWidgets(
    'custom delay/labels and zero delay; loader off hides everything',
    (tester) async {
      final c = LoadingController()..value = video(buffering: true);
      await tester.pumpWidget(
        host(
          c,
          controls: false,
          configuration: const LumioControlsConfiguration(
            bufferingIndicatorDelay: Duration(milliseconds: 100),
            bufferingLabel: 'Aguardando dados',
            reconnectingLabel: 'Reconectando à câmera…',
          ),
        ),
      );
      await tester.pump(const Duration(milliseconds: 99));
      expect(badge, findsNothing);
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.text('Aguardando dados'), findsOneWidget);
      c.recoveryPending = true;
      c.value = c.value.copyWith(
        error: const LumioPlayerError(
          code: 'network',
          message: 'temporary',
          recoverable: true,
        ),
      );
      await tester.pump();
      expect(find.text('Reconectando à câmera…'), findsOneWidget);
      await tester.pumpWidget(
        host(
          c,
          configuration: const LumioControlsConfiguration(showLoader: false),
        ),
      );
      expect(find.byType(CircularProgressIndicator), findsNothing);
      expect(find.textContaining('Playback failed'), findsNothing);
      c.recoveryPending = false;
      c.value = video(buffering: true);
      await tester.pumpWidget(
        host(
          c,
          controls: false,
          configuration: const LumioControlsConfiguration(
            bufferingIndicatorDelay: Duration.zero,
          ),
        ),
      );
      expect(badge, findsOneWidget);
      await close(tester, c);
    },
  );

  testWidgets(
    'recovery before playback remains central with reconnection label',
    (tester) async {
      final c = LoadingController()..recoveryPending = true;
      c.value = LumioPlayerState(
        error: const LumioPlayerError(
          code: 'network',
          message: 'temporary',
          recoverable: true,
        ),
      );
      await tester.pumpWidget(host(c, controls: false));
      expect(central, findsOneWidget);
      expect(badge, findsNothing);
      expect(find.text('Reconectando…'), findsOneWidget);
      expect(find.textContaining('Playback failed'), findsNothing);
      await close(tester, c);
    },
  );

  testWidgets(
    'pending recovery suppresses fatal builder; exhausted recovery is terminal',
    (tester) async {
      final c = LoadingController()..value = video();
      var errors = 0;
      Widget build() => MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            child: LumioPlayerView(
              controller: c,
              errorBuilder: (_, error) {
                errors++;
                return const Text('Fatal custom error');
              },
            ),
          ),
        ),
      );
      await tester.pumpWidget(build());
      c.value = c.value.copyWith(
        error: const LumioPlayerError(
          code: 'network',
          message: 'temporary',
          recoverable: true,
        ),
      );
      // Like _scheduleRecovery: publish the error, then schedule backoff before
      // Flutter builds, without a second state notification.
      c.recoveryPending = true;
      await tester.pump();
      expect(c.value.phase, LumioPlaybackPhase.failed);
      expect(errors, 0);
      expect(find.text('Reconectando…'), findsOneWidget);
      c.value = LumioPlayerState(transitioning: true, buffering: true);
      await tester.pump();
      expect(central, findsNothing);
      expect(badge, findsOneWidget);
      c.recoveryPending = false;
      c.value = LumioPlayerState(
        error: const LumioPlayerError(
          code: 'network',
          message: 'budget exhausted',
          recoverable: true,
        ),
      );
      await tester.pump();
      expect(errors, greaterThan(0));
      expect(find.text('Fatal custom error'), findsOneWidget);
      expect(find.byTooltip('Retry'), findsOneWidget);
      expect(badge, findsNothing);
      await tester.tap(find.byTooltip('Retry'));
      await tester.pump();
      expect(c.value.error, isNull);
      await close(tester, c);
    },
  );

  for (final change in ['source', 'index', 'controller', 'dispose']) {
    testWidgets('$change cancels the old visual timer and resets history', (
      tester,
    ) async {
      final c = LoadingController()..value = video();
      await tester.pumpWidget(host(c, controls: false));
      c.value = video(buffering: true);
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 400));
      LoadingController? next;
      if (change == 'source') {
        c.testSource = LumioSource.network(
          Uri.parse('https://example.com/new'),
        );
        c.value = LumioPlayerState(buffering: true);
      } else if (change == 'index') {
        c.testPlaylistIndex++;
        c.value = LumioPlayerState(buffering: true);
      } else if (change == 'controller') {
        next = LoadingController();
        await tester.pumpWidget(host(next, controls: false));
      } else {
        await tester.pumpWidget(const SizedBox.shrink());
      }
      await tester.pump(delay);
      expect(badge, findsNothing);
      expect(central, change == 'dispose' ? findsNothing : findsOneWidget);
      await close(tester, c);
      if (next != null) await next.dispose();
    });
  }

  testWidgets(
    'same-source engine fallback and remount preserve observed playback',
    (tester) async {
      final c = LoadingController()..value = video();
      await tester.pumpWidget(host(c, controls: false));
      c.value = LumioPlayerState(
        engine: LumioPlaybackEngine.webview,
        buffering: true,
        transitioning: true,
      );
      await tester.pump();
      expect(central, findsNothing);
      await tester.pump(delay);
      expect(badge, findsOneWidget);
      await tester.pumpWidget(const SizedBox.shrink());
      await tester.pumpWidget(host(c, controls: false, isFullscreen: true));
      expect(central, findsNothing);
      await tester.pump(delay);
      expect(badge, findsOneWidget);
      await close(tester, c);
    },
  );

  testWidgets('internal fullscreen transfers loading history during recovery', (
    tester,
  ) async {
    final c = LoadingController()..value = video();
    await tester.pumpWidget(host(c));
    c.recoveryPending = true;
    c.value = video(buffering: true);
    await tester.pump();
    await tester.tap(find.byTooltip('Fullscreen'));
    for (var i = 0; i < 8; i++) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(central, findsNothing);
    expect(badge, findsOneWidget);
    c.value = LumioPlayerState(buffering: true, transitioning: true);
    await tester.pump();
    expect(find.text('Reconectando…'), findsOneWidget);
    expect(central, findsNothing);
    await close(tester, c);
  });
}
