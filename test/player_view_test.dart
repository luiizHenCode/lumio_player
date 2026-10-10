import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/controller.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

class TestController extends LumioPlayerController {
  TestController({super.configuration});
  bool fail = false;
  Duration? sought;
  final speeds = <double>[];
  LumioSource? testSource;
  bool gain = true;
  @override
  LumioSource? get source => testSource;
  @override
  LumioCapabilities get capabilities => LumioCapabilities(
    engine: value.engine,
    network: true,
    localFiles: true,
    assets: true,
    httpHeaders: true,
    formats: const {},
    detailedBufferControl: false,
    volumeControl: gain,
  );
  @override
  int? get textureId => value.initialized ? 42 : null;
  @override
  Future<void> play() async {
    if (fail) throw StateError('secret URL must not be displayed');
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> pause() async {
    value = value.copyWith(playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> seekTo(Duration position) async {
    sought = position;
  }

  @override
  Future<void> retry() async {
    value = value.copyWith(clearError: true);
  }

  @override
  Future<void> restoreSpeedIfUnchanged({
    required int revision,
    required double temporarySpeed,
    required double originalSpeed,
  }) async {
    if (value.speed == temporarySpeed) await setSpeed(originalSpeed);
  }

  @override
  Future<void> setSpeed(double speed) async {
    speeds.add(speed);
    value = value.copyWith(speed: speed);
  }
}

Widget host(
  LumioPlayerController controller, {
  bool controls = true,
  double width = 300,
  LumioControlsConfiguration configuration = const LumioControlsConfiguration(),
  String? title,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        child: LumioPlayerView(
          controller: controller,
          controls: controls,
          controlsConfiguration: configuration,
          title: title,
        ),
      ),
    ),
  ),
);

Future<void> close(
  WidgetTester tester,
  LumioPlayerController controller,
) async {
  await tester.pumpWidget(const SizedBox.shrink());
  // Drain Flutter's double-tap minimum-interval trackers after pointer teardown.
  await tester.pump(const Duration(milliseconds: 350));
  final closing = controller.dispose();
  await tester.pump();
  await closing;
}

const allOff = LumioControlsConfiguration(
  showPlayPause: false,
  showProgress: false,
  showSpeed: false,
  showSkipButtons: false,
  showVolume: false,
  showPlaylistNavigation: false,
  showSettings: false,
  showTime: false,
  showTitle: false,
  showRetry: false,
  showLiveButton: false,
  showLoader: false,
  doubleTapSeek: false,
  holdToSpeed: false,
);

void main() {
  testWidgets('video time is aligned with progress at its right edge', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        position: Duration(seconds: 4),
        duration: Duration(seconds: 77),
      );
    await tester.pumpWidget(host(controller, width: 300, title: 'Video title'));
    final slider = tester.getRect(find.byKey(const ValueKey('lumio-progress')));
    final time = tester.getRect(
      find.byKey(const ValueKey('lumio-progress-time')),
    );
    expect(find.text('0:04 / 1:17'), findsOneWidget);
    expect(time.center.dy, closeTo(slider.center.dy, 0.1));
    expect(time.left, greaterThanOrEqualTo(slider.right));
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('time remains available when progress is hidden', (tester) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
      );
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showProgress: false),
      ),
    );
    expect(find.byKey(const ValueKey('lumio-progress-row')), findsNothing);
    expect(find.text('0:00 / 1:00'), findsOneWidget);
    await close(tester, controller);
  });

  test('configuration defaults and runtime validation', () {
    const defaults = LumioControlsConfiguration();
    defaults.validate();
    expect(defaults.playbackSpeeds, [1, 1.5, 2, 3, 4]);
    expect(defaults.seekInterval, const Duration(seconds: 10));
    expect(defaults.holdSpeed, 2);
    expect(defaults.maxZoom, 4);
    expect(defaults.compact, false);
    for (final speeds in <List<double>>[
      [],
      [1, 1],
      [double.nan],
      [double.infinity],
      [.24],
      [4.01],
    ]) {
      expect(
        () => LumioControlsConfiguration(playbackSpeeds: speeds).validate(),
        throwsArgumentError,
      );
    }
    const LumioControlsConfiguration(
      showSpeed: false,
      playbackSpeeds: [],
    ).validate();
    const LumioControlsConfiguration(
      enabled: false,
      playbackSpeeds: [],
    ).validate();
    expect(
      () => const LumioControlsConfiguration(holdSpeed: 5).validate(),
      throwsArgumentError,
    );
    expect(
      () =>
          const LumioControlsConfiguration(maxZoom: double.infinity).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LumioControlsConfiguration(
        seekInterval: Duration.zero,
      ).validate(),
      throwsArgumentError,
    );
    expect(
      () => const LumioControlsConfiguration(
        compactDelay: Duration.zero,
      ).validate(),
      throwsArgumentError,
    );
  });

  testWidgets('default controls and custom title are responsive at 200px', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 2),
      );
    await tester.pumpWidget(
      host(
        controller,
        width: 200,
        title: 'A long broadcast title that must truncate',
      ),
    );
    for (final tooltip in [
      'Play',
      'Seek backward',
      'Seek forward',
      'Mute',
      'Playback speed',
      'Playback engine',
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('lumio-progress')), findsOneWidget);
    expect(find.byKey(const ValueKey('lumio-volume')), findsOneWidget);
    expect(find.textContaining('A long broadcast'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('all switches off and master disable leave no chrome', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        buffering: true,
        error: LumioPlayerError(code: 'test', message: 'Failure'),
      );
    await tester.pumpWidget(
      host(controller, configuration: allOff, title: 'Hidden'),
    );
    expect(find.byType(IconButton), findsNothing);
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(PopupMenuButton<double>), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsNothing);
    expect(find.text('Hidden'), findsNothing);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(enabled: false),
      ),
    );
    expect(find.byType(LumioPlayerControls), findsNothing);
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await tester.pumpWidget(host(controller, controls: false));
    expect(find.byType(CircularProgressIndicator), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('individual switches remove only their own UI', (tester) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
        error: LumioPlayerError(code: 'test', message: 'Failure'),
      );
    final cases = <(LumioControlsConfiguration, Finder)>[
      (
        const LumioControlsConfiguration(showPlayPause: false),
        find.byTooltip('Play'),
      ),
      (
        const LumioControlsConfiguration(showProgress: false),
        find.byKey(const ValueKey('lumio-progress')),
      ),
      (
        const LumioControlsConfiguration(showSpeed: false),
        find.byTooltip('Playback speed'),
      ),
      (
        const LumioControlsConfiguration(showSkipButtons: false),
        find.byTooltip('Seek forward'),
      ),
      (
        const LumioControlsConfiguration(showVolume: false),
        find.byTooltip('Mute'),
      ),
      (
        const LumioControlsConfiguration(showSettings: false),
        find.byTooltip('Playback engine'),
      ),
      (const LumioControlsConfiguration(showTitle: false), find.text('Title')),
      (
        const LumioControlsConfiguration(showTime: false),
        find.text('0:00 / 1:00'),
      ),
      (
        const LumioControlsConfiguration(showRetry: false),
        find.byTooltip('Retry'),
      ),
    ];
    for (final (configuration, finder) in cases) {
      await tester.pumpWidget(host(controller, title: 'Title'));
      expect(finder, findsOneWidget);
      await tester.pumpWidget(
        host(controller, title: 'Title', configuration: configuration),
      );
      expect(finder, findsNothing);
      expect(find.byType(Texture), findsOneWidget);
    }
    controller.value = controller.value.copyWith(live: true, clearError: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showLiveButton: false),
      ),
    );
    expect(find.byTooltip('Return to live'), findsNothing);
    expect(find.textContaining('LIVE'), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('standalone speed-only controls use custom speeds', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: LumioPlayerControls(
            controller: controller,
            configuration: const LumioControlsConfiguration(
              showPlayPause: false,
              showProgress: false,
              showSkipButtons: false,
              showVolume: false,
              showPlaylistNavigation: false,
              showSettings: false,
              showTime: false,
              showTitle: false,
              showRetry: false,
              showLiveButton: false,
              playbackSpeeds: [.25, .75, 3.5],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pumpAndSettle();
    expect(find.text('0.25x'), findsOneWidget);
    expect(find.text('2.0x'), findsNothing);
    await tester.tap(find.text('3.5x'));
    await tester.pumpAndSettle();
    expect(controller.value.speed, 3.5);
    await close(tester, controller);
  });

  testWidgets('volume gain and mute-only capability', (tester) async {
    final controller = TestController()
      ..value = const LumioPlayerState(initialized: true);
    await tester.pumpWidget(host(controller));
    tester
        .widget<Slider>(find.byKey(const ValueKey('lumio-volume')))
        .onChanged!(.4);
    await tester.pump();
    expect(controller.value.volume, .4);
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump();
    expect(controller.value.volume, .4);
    controller.gain = false;
    controller.value = controller.value.copyWith(volume: 1);
    await tester.pump();
    expect(find.byKey(const ValueKey('lumio-volume')), findsNothing);
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    await tester.tap(find.byTooltip('Unmute'));
    await tester.pump();
    expect(controller.value.volume, 1);
    await close(tester, controller);
  });

  testWidgets('progress keeps local drag through position notifications', (
    tester,
  ) async {
    final controller = TestController()
      ..value = const LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 2),
      );
    await tester.pumpWidget(host(controller));
    final finder = find.byKey(const ValueKey('lumio-progress'));
    tester.widget<Slider>(finder).onChangeStart!(0);
    tester.widget<Slider>(finder).onChanged!(90000);
    controller.value = controller.value.copyWith(
      position: const Duration(seconds: 5),
    );
    await tester.pump();
    expect(tester.widget<Slider>(finder).value, 90000);
    expect(controller.sought, isNull);
    tester.widget<Slider>(finder).onChangeEnd!(90000);
    await tester.pump();
    expect(controller.sought, const Duration(seconds: 90));
    await close(tester, controller);
  });

  testWidgets('idle, custom placeholder, audio and optional controls', (
    tester,
  ) async {
    final controller = TestController(
      configuration: const LumioPlayerConfiguration(
        mode: LumioPlaybackMode.audio,
      ),
    );
    await tester.pumpWidget(host(controller, controls: false));
    expect(find.byIcon(Icons.audiotrack), findsOneWidget);
    expect(find.byType(LumioPlayerControls), findsNothing);
    await tester.pumpWidget(
      MaterialApp(
        home: LumioPlayerView(
          controller: controller,
          controls: false,
          placeholder: (_, _) => const Text('Custom placeholder'),
        ),
      ),
    );
    expect(find.text('Custom placeholder'), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('texture, play/pause, mute, speed and VOD slider', (
    tester,
  ) async {
    final controller = TestController();
    controller.value = const LumioPlayerState(
      initialized: true,
      duration: Duration(minutes: 2),
    );
    await tester.pumpWidget(host(controller));
    expect(find.byType(Texture), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(controller.value.playing, false);
    expect(controller.value.volume, 0);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('1.5x'));
    await tester.pumpAndSettle();
    expect(controller.value.speed, 1.5);
    final slider = tester.widget<Slider>(
      find.byKey(const ValueKey('lumio-progress')),
    );
    slider.onChanged!(60000);
    await tester.pump();
    expect(controller.sought, isNull);
    slider.onChangeEnd!(60000);
    await tester.pump();
    expect(controller.sought, const Duration(minutes: 1));
    expect(find.text('0:00 / 2:00'), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('narrow controls, live mode and error retry', (tester) async {
    final controller = TestController();
    controller.value = const LumioPlayerState(
      live: true,
      error: LumioPlayerError(code: 'test', message: 'Failure'),
    );
    await tester.pumpWidget(host(controller, width: 180));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
    expect(find.textContaining('LIVE'), findsOneWidget);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pump();
    expect(controller.value.error, isNull);
    await close(tester, controller);
  });

  testWidgets('failed asynchronous commands expose safe feedback', (
    tester,
  ) async {
    final controller = TestController()..fail = true;
    controller.value = const LumioPlayerState(initialized: true);
    await tester.pumpWidget(host(controller));
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(find.textContaining('Player command failed'), findsOneWidget);
    expect(find.textContaining('secret URL'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });
}
