import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

import 'player_view_test.dart' show TestController, close, host;

class _Controller extends TestController {
  final commands = <String>[];

  @override
  Future<void> play({bool Function()? isCurrent}) async {
    commands.add('play');
    await super.play(isCurrent: isCurrent);
  }

  @override
  Future<void> pause({bool Function()? isCurrent}) async {
    commands.add('pause');
    await super.pause(isCurrent: isCurrent);
  }

  @override
  Future<void> setVolume(double volume) async {
    commands.add('volume');
    await super.setVolume(volume);
  }

  @override
  Future<void> setSpeed(double speed) async {
    commands.add('speed');
    await super.setSpeed(speed);
  }

  @override
  Future<void> seekTo(Duration position, {bool Function()? isCurrent}) async {
    commands.add('seek');
    await super.seekTo(position, isCurrent: isCurrent);
  }

  @override
  Future<void> previous() async {
    commands.add('previous');
    await super.previous();
  }

  @override
  Future<void> next() async {
    commands.add('next');
    await super.next();
  }

  @override
  Future<void> retry() async {
    commands.add('retry');
    await super.retry();
  }
}

const _delay = Duration(seconds: 1);
const _elapsed = Duration(seconds: 2);
final _compact = find.byKey(const ValueKey('lumio-compact-controls'));
final _progress = find.byKey(const ValueKey('lumio-progress'));

LumioControlsConfiguration _configuration(
  LumioControlsPlacement placement,
  LumioControlsLayout layout, {
  LumioSimplifiedControl simplified = LumioSimplifiedControl.speed,
  bool enabled = true,
}) => LumioControlsConfiguration(
  placement: placement,
  layout: layout,
  simplifiedControl: simplified,
  compact: true,
  compactDelay: _delay,
  showSettings: true,
  showStatistics: true,
  showVolumeSlider: true,
  enabled: enabled,
);

_Controller _controller({bool transitioning = false, bool live = false}) =>
    _Controller()
      ..testPlaylist = LumioPlaylist([
        for (final name in ['one', 'two', 'three'])
          LumioPlaylistItem(
            source: LumioSource.network(
              Uri.parse('https://example.com/$name.mp4'),
            ),
          ),
      ])
      ..testPlaylistIndex = 1
      ..value = LumioPlayerState(
        initialized: transitioning,
        transitioning: transitioning,
        playing: true,
        live: live,
        duration: const Duration(minutes: 2),
        position: const Duration(seconds: 20),
      );

void _expectCallbacks(WidgetTester tester, {required bool enabled}) {
  final icons = find.byType(IconButton);
  expect(icons, findsWidgets);
  for (final button in tester.widgetList<IconButton>(icons)) {
    expect(
      button.onPressed,
      enabled ? isNotNull : isNull,
      reason: button.tooltip,
    );
  }
  for (final button in tester.widgetList<TextButton>(find.byType(TextButton))) {
    expect(button.onPressed, enabled ? isNotNull : isNull);
    expect(button.onLongPress, enabled ? isNotNull : isNull);
  }
  for (final slider in tester.widgetList<Slider>(find.byType(Slider))) {
    expect(slider.onChanged, enabled ? isNotNull : isNull);
    expect(slider.onChangeStart, enabled ? isNotNull : isNull);
    expect(slider.onChangeEnd, enabled ? isNotNull : isNull);
  }
  final settings = tester.widget<PopupMenuButton<LumioPlaybackEngine>>(
    find.byType(PopupMenuButton<LumioPlaybackEngine>),
  );
  expect(settings.enabled, enabled);
}

Future<void> _tapSurface(WidgetTester tester) async {
  await tester.tapAt(
    tester
            .getRect(find.byKey(const ValueKey('lumio-gesture-surface')))
            .topCenter +
        const Offset(0, 20),
  );
  await tester.pump(const Duration(milliseconds: 350));
}

Widget _externalHost(
  _Controller controller,
  ValueNotifier<bool> compacted,
  LumioControlsConfiguration configuration,
) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: 600,
        child: LumioPlayerView(
          controller: controller,
          controlsConfiguration: configuration,
          compactedController: compacted,
          onToggleFullscreen: () {},
        ),
      ),
    ),
  ),
);

void main() {
  for (final brightness in Brightness.values) {
    testWidgets(
      'disabled compact buttons remain readable with $brightness host theme',
      (tester) async {
        final controller = _controller();
        await tester.pumpWidget(
          MaterialApp(
            theme: ThemeData(
              brightness: brightness,
              disabledColor: Colors.transparent,
              iconButtonTheme: const IconButtonThemeData(
                style: ButtonStyle(
                  foregroundColor: WidgetStatePropertyAll(Colors.transparent),
                ),
              ),
              textButtonTheme: TextButtonThemeData(
                style: TextButton.styleFrom(
                  disabledForegroundColor: Colors.transparent,
                ),
              ),
            ),
            home: Scaffold(
              body: SizedBox(
                width: 600,
                child: LumioPlayerControls(
                  controller: controller,
                  configuration: const LumioControlsConfiguration(
                    compact: true,
                    layout: LumioControlsLayout.simplified,
                    placement: LumioControlsPlacement.overlay,
                  ),
                ),
              ),
            ),
          ),
        );
        final play = find.byIcon(Icons.pause);
        expect(play, findsOneWidget);
        final iconColor = IconTheme.of(tester.element(play)).color!;
        expect(iconColor, Colors.white.withValues(alpha: .55));
        final speed = find.text('1x');
        expect(speed, findsOneWidget);
        final textColor = DefaultTextStyle.of(
          tester.element(speed),
        ).style.color!;
        expect(textColor, Colors.white.withValues(alpha: .55));
        expect(
          tester.widget<IconButton>(find.byType(IconButton)).onPressed,
          isNull,
        );
        expect(
          tester.widget<TextButton>(find.byType(TextButton)).onPressed,
          isNull,
        );
        await close(tester, controller);
      },
    );
  }
  for (final placement in LumioControlsPlacement.values) {
    for (final variant in [
      (LumioControlsLayout.complete, LumioSimplifiedControl.speed),
      (LumioControlsLayout.simplified, LumioSimplifiedControl.speed),
      (LumioControlsLayout.simplified, LumioSimplifiedControl.volume),
      (LumioControlsLayout.live, LumioSimplifiedControl.speed),
    ]) {
      final (layout, simplified) = variant;
      final live = layout == LumioControlsLayout.live;
      for (final transitioning in [false, true]) {
        testWidgets(
          '$placement/$layout/$simplified stays expanded and disabled during '
          '${transitioning ? 'transition' : 'initialization'}, then enables and auto-hides',
          (tester) async {
            final controller = _controller(
              transitioning: transitioning,
              live: live,
            );
            var fullscreenCalls = 0;
            await tester.pumpWidget(
              host(
                controller,
                width: 600,
                onToggleFullscreen: () => fullscreenCalls++,
                configuration: _configuration(
                  placement,
                  layout,
                  simplified: simplified,
                ),
              ),
            );
            await tester.pump(_elapsed);
            expect(_compact, findsNothing);
            expect(
              find.byKey(ValueKey('lumio-${layout.name}-layout')),
              findsOneWidget,
            );
            expect(_progress, live ? findsNothing : findsOneWidget);
            _expectCallbacks(tester, enabled: false);

            for (final button
                in tester
                    .widgetList<IconButton>(find.byType(IconButton))
                    .toList()) {
              await tester.tap(find.byTooltip(button.tooltip!));
              await tester.pump();
            }
            if (find.byTooltip('Playback speed').evaluate().isNotEmpty) {
              await tester.tap(find.byTooltip('Playback speed'));
              await tester.longPress(find.byTooltip('Playback speed'));
              await tester.pump();
            }
            for (final slider in find.byType(Slider).evaluate().toList()) {
              await tester.tap(find.byWidget(slider.widget));
              await tester.pump();
            }
            await tester.tap(find.byTooltip('Playback engine'));
            await tester.pump();
            expect(
              find.byType(PopupMenuItem<LumioPlaybackEngine>),
              findsNothing,
            );
            expect(controller.commands, isEmpty);
            expect(fullscreenCalls, 0);
            expect(controller.playlistIndex, 1);
            expect(tester.takeException(), isNull);
            await tester.pump(_elapsed);
            expect(_compact, findsNothing);

            controller.value = controller.value.copyWith(
              initialized: true,
              transitioning: false,
            );
            await tester.pump();
            _expectCallbacks(tester, enabled: true);
            await tester.pump(_elapsed);
            expect(_compact, findsOneWidget);
            expect(find.byType(IconButton), findsNothing);
            await _tapSurface(tester);
            expect(_compact, findsNothing);
            _expectCallbacks(tester, enabled: true);
            final action = live || simplified == LumioSimplifiedControl.volume
                ? 'Mute'
                : 'Pause';
            await tester.tap(find.byTooltip(action));
            await tester.pump();
            expect(controller.commands, [
              action == 'Mute' ? 'volume' : 'pause',
            ]);
            await close(tester, controller);
          },
        );
      }
    }

    for (final transitioning in [false, true]) {
      testWidgets(
        '$placement externally hidden loading expands temporarily without changing choice ($transitioning)',
        (tester) async {
          final controller = _controller(transitioning: transitioning);
          final compacted = ValueNotifier(true);
          final changes = <bool>[];
          compacted.addListener(() => changes.add(compacted.value));
          await tester.pumpWidget(
            _externalHost(
              controller,
              compacted,
              _configuration(placement, LumioControlsLayout.complete),
            ),
          );
          await tester.pump(_elapsed);
          expect(_compact, findsNothing);
          expect(_progress, findsOneWidget);
          _expectCallbacks(tester, enabled: false);
          expect(compacted.value, isTrue);
          expect(changes, isEmpty);
          controller.value = controller.value.copyWith(
            initialized: true,
            transitioning: false,
          );
          await tester.pump();
          expect(_compact, findsOneWidget);
          expect(compacted.value, isTrue);
          expect(changes, isEmpty);

          controller.value = controller.value.copyWith(transitioning: true);
          await tester.pump();
          await tester.pump(_elapsed);
          expect(_compact, findsNothing);
          expect(_progress, findsOneWidget);
          _expectCallbacks(tester, enabled: false);
          expect(compacted.value, isTrue);
          expect(changes, isEmpty);
          controller.value = controller.value.copyWith(transitioning: false);
          await tester.pump();
          expect(_compact, findsOneWidget);
          expect(changes, isEmpty);
          await close(tester, controller);
          compacted.dispose();
        },
      );
    }

    testWidgets('$placement error keeps retry callable in compact mode', (
      tester,
    ) async {
      final controller = _controller();
      final compacted = ValueNotifier(true);
      await tester.pumpWidget(
        _externalHost(
          controller,
          compacted,
          _configuration(placement, LumioControlsLayout.complete),
        ),
      );
      controller.value = controller.value.copyWith(
        playing: false,
        error: const LumioPlayerError(code: 'test', message: 'Failure'),
      );
      await tester.pump();
      final retry = find.byTooltip('Retry');
      expect(retry, findsOneWidget);
      expect(
        tester
            .widget<IconButton>(
              find.byWidgetPredicate(
                (widget) => widget is IconButton && widget.tooltip == 'Retry',
              ),
            )
            .onPressed,
        isNotNull,
      );
      await tester.tap(retry);
      await tester.pump();
      expect(controller.commands, ['retry']);
      expect(controller.value.error, isNull);
      expect(_compact, findsNothing);
      expect(_progress, findsOneWidget);
      _expectCallbacks(tester, enabled: false);
      await close(tester, controller);
      compacted.dispose();
    });

    for (final disableConfiguration in [false, true]) {
      testWidgets(
        '$placement ${disableConfiguration ? 'enabled=false' : 'controls=false'} still hides loading controls',
        (tester) async {
          final controller = _controller();
          controller.value = controller.value.copyWith(buffering: true);
          await tester.pumpWidget(
            host(
              controller,
              width: 600,
              controls: disableConfiguration,
              configuration: _configuration(
                placement,
                LumioControlsLayout.complete,
                enabled: !disableConfiguration,
              ),
            ),
          );
          await tester.pump(_elapsed);
          expect(find.byType(IconButton), findsNothing);
          expect(find.byType(TextButton), findsNothing);
          expect(find.byType(Slider), findsNothing);
          expect(_compact, findsNothing);
          expect(find.byType(LumioPlayerControls), findsNothing);
          expect(find.byType(CircularProgressIndicator), findsOneWidget);
          await _tapSurface(tester);
          expect(controller.commands, isEmpty);
          await close(tester, controller);
        },
      );
    }
  }
}
