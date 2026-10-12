import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/controller.dart';
import 'package:lumio_player/src/models.dart';
import 'package:lumio_player/src/player_view.dart';

class TestController extends LumioPlayerController {
  TestController({super.configuration});
  bool fail = false;
  Duration? sought;
  int liveSeeks = 0;
  final speeds = <double>[];
  LumioSource? testSource;
  bool gain = true;
  LumioPlaylist? testPlaylist;
  int testPlaylistIndex = 0;
  @override
  LumioPlaylist? get playlist => testPlaylist;
  @override
  int get playlistIndex => testPlaylistIndex;
  @override
  LumioPlaylistItem? get currentItem => testPlaylist?.items[testPlaylistIndex];
  @override
  bool get hasPrevious => testPlaylist != null && testPlaylistIndex > 0;
  @override
  bool get hasNext =>
      testPlaylist != null &&
      testPlaylistIndex < testPlaylist!.items.length - 1;
  @override
  Future<void> previous() async {
    if (hasPrevious) testPlaylistIndex--;
    notifyListeners();
  }

  @override
  Future<void> next() async {
    if (hasNext) testPlaylistIndex++;
    notifyListeners();
  }

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
  Future<void> play({bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    if (fail) throw StateError('secret URL must not be displayed');
    value = value.copyWith(playing: true);
  }

  @override
  Future<void> pause({bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    value = value.copyWith(playing: false);
  }

  @override
  Future<void> setVolume(double volume) async {
    value = value.copyWith(volume: volume);
  }

  @override
  Future<void> seekTo(Duration position, {bool Function()? isCurrent}) async {
    if (isCurrent != null && !isCurrent()) throw StateError('Stale command.');
    sought = position;
  }

  @override
  Future<void> seekToPreview(Duration position, {bool Function()? isCurrent}) =>
      seekTo(position, isCurrent: isCurrent);

  @override
  Future<void> seekToLive() async {
    liveSeeks++;
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
  double? height,
  LumioVideoLayout videoLayout = LumioVideoLayout.aspectRatio,
  double? aspectRatio,
  LumioControlsConfiguration configuration = const LumioControlsConfiguration(),
  String? title,
  VoidCallback? onToggleFullscreen,
  bool isFullscreen = false,
  GlobalKey? surfaceCaptureKey,
}) => MaterialApp(
  home: Scaffold(
    body: Center(
      child: SizedBox(
        width: width,
        height: height,
        child: LumioPlayerView(
          controller: controller,
          controls: controls,
          layout: videoLayout,
          aspectRatio: aspectRatio,
          controlsConfiguration: configuration,
          title: title,
          onToggleFullscreen: onToggleFullscreen,
          isFullscreen: isFullscreen,
          surfaceCaptureKey: surfaceCaptureKey,
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
  showStatus: false,
  showFullscreen: false,
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
  for (final placement in LumioControlsPlacement.values) {
    testWidgets('compact progress respects $placement edge and thickness', (
      tester,
    ) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          playing: true,
          duration: Duration(seconds: 100),
          position: Duration(seconds: 25),
        );
      await tester.pumpWidget(
        host(
          controller,
          width: 600,
          configuration: LumioControlsConfiguration(
            placement: placement,
            compact: true,
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 5));
      final progress = tester.getRect(
        find.byKey(const ValueKey('lumio-compact-progress')),
      );
      final controls = tester.getRect(
        find.byKey(const ValueKey('lumio-compact-controls')),
      );
      if (placement == LumioControlsPlacement.overlay) {
        final media = tester.getRect(
          find.byKey(const ValueKey('lumio-gesture-surface')),
        );
        expect(progress.height, 4);
        expect(progress.bottom, media.bottom);
        expect(progress.bottom, controls.bottom);
        expect(progress.top, controls.top);
        expect(controls.height, 4);
      } else {
        expect(progress.height, 2);
        expect(progress.top, controls.top);
      }
      expect(progress.width, controls.width);
      await close(tester, controller);
    });

    testWidgets(
      'surfaceCaptureKey excludes $placement controls and survives fullscreen',
      (tester) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true);
        final captureKey = GlobalKey();
        await tester.pumpWidget(
          host(
            controller,
            width: 600,
            surfaceCaptureKey: captureKey,
            configuration: LumioControlsConfiguration(placement: placement),
          ),
        );

        void expectCaptureSurface({required bool fullscreen}) {
          final boundary = find.byKey(captureKey, skipOffstage: false);
          expect(boundary, findsOneWidget);
          expect(tester.widget(boundary), isA<RepaintBoundary>());
          expect(
            find.descendant(of: boundary, matching: find.byType(Texture)),
            findsOneWidget,
          );
          expect(
            find.descendant(
              of: boundary,
              matching: find.byType(LumioPlayerControls),
            ),
            findsNothing,
          );
          expect(find.byType(LumioPlayerControls), findsOneWidget);
          final view = tester.widget<LumioPlayerView>(
            find
                .ancestor(of: boundary, matching: find.byType(LumioPlayerView))
                .first,
          );
          expect(view.surfaceCaptureKey, same(captureKey));
          expect(view.isFullscreen, fullscreen);
          expect(tester.takeException(), isNull);
        }

        expectCaptureSurface(fullscreen: false);
        await tester.tap(find.byTooltip('Fullscreen'));
        // The inline boundary must unmount before the route takes ownership.
        await tester.pump();
        expect(find.byKey(captureKey, skipOffstage: false), findsNothing);
        expect(tester.takeException(), isNull);
        await tester.pumpAndSettle();
        expectCaptureSurface(fullscreen: true);
        await tester.tap(find.byTooltip('Exit fullscreen'));
        await tester.pumpAndSettle();
        expectCaptureSurface(fullscreen: false);
        await close(tester, controller);
      },
    );
  }

  for (final layout in [
    LumioControlsLayout.complete,
    LumioControlsLayout.simplified,
  ]) {
    for (final width in [300.0, 600.0]) {
      testWidgets(
        '$layout uses reduced horizontal padding and labels at $width',
        (tester) async {
          final controller = TestController()
            ..value = LumioPlayerState(
              initialized: true,
              playing: true,
              duration: Duration(minutes: 5),
            );
          await tester.pumpWidget(
            host(
              controller,
              width: width,
              configuration: LumioControlsConfiguration(layout: layout),
            ),
          );
          final controls = tester.getRect(find.byType(LumioPlayerControls));
          final row = tester.getRect(
            find.byKey(
              ValueKey(
                layout == LumioControlsLayout.complete
                    ? 'lumio-complete-layout'
                    : 'lumio-simplified-layout',
              ),
            ),
          );
          expect(row.left, closeTo(controls.left + 12, .1));
          expect(row.right, closeTo(controls.right - 12, .1));
          for (final key in ['lumio-playback-status', 'lumio-progress-time']) {
            expect(
              tester.widget<Text>(find.byKey(ValueKey(key))).style?.fontSize,
              11,
            );
          }
          expect(tester.takeException(), isNull);
          await close(tester, controller);
        },
      );
    }

    testWidgets(
      '$layout cycles speed and long press resets without advancing',
      (tester) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true);
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(layout: layout),
          ),
        );
        final speed = find.byTooltip('Playback speed');
        expect(find.text('1x'), findsOneWidget);
        expect(tester.getSize(speed).height, 40);
        expect(
          find.descendant(of: speed, matching: find.byType(TextButton)),
          findsOneWidget,
        );
        for (final next in [2, 3, 4, 1]) {
          await tester.tap(speed);
          await tester.pump();
          expect(controller.value.speed, next);
          expect(find.text('${next}x'), findsOneWidget);
          expect(
            tester.widget<Text>(find.text('${next}x')).style?.fontSize,
            16,
          );
          expect(find.byType(PopupMenuItem<double>), findsNothing);
        }
        expect(controller.speeds, [2, 3, 4, 1]);
        controller.value = controller.value.copyWith(speed: 1.5);
        await tester.pump();
        await tester.tap(speed);
        await tester.pump();
        expect(controller.speeds, [2, 3, 4, 1, 1]);
        controller.value = controller.value.copyWith(speed: 4);
        await tester.pump();
        final gesture = await tester.startGesture(tester.getCenter(speed));
        await tester.pump(const Duration(milliseconds: 700));
        expect(controller.value.speed, 1);
        expect(controller.speeds, [2, 3, 4, 1, 1, 1]);
        await gesture.up();
        await tester.pump();
        expect(controller.speeds, [2, 3, 4, 1, 1, 1]);
        await close(tester, controller);
      },
    );

    testWidgets(
      '$layout cycles fractional custom speeds and resets outside list',
      (tester) async {
        final controller = TestController()
          ..value = LumioPlayerState(initialized: true);
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(
              layout: layout,
              playbackSpeeds: [.25, 3.5],
            ),
          ),
        );
        final speed = find.byTooltip('Playback speed');
        for (final next in [.25, 3.5, .25, 3.5]) {
          await tester.tap(speed);
          await tester.pump();
          expect(controller.value.speed, next);
          expect(find.text('${next}x'), findsOneWidget);
        }
        expect(controller.speeds, [.25, 3.5, .25, 3.5]);
        final gesture = await tester.startGesture(tester.getCenter(speed));
        await tester.pump(const Duration(milliseconds: 700));
        expect(find.text('1x'), findsOneWidget);
        expect(controller.speeds, [.25, 3.5, .25, 3.5, 1]);
        await gesture.up();
        await tester.pump();
        expect(controller.speeds, [.25, 3.5, .25, 3.5, 1]);
        await tester.tap(speed);
        await tester.pump();
        expect(controller.speeds, [.25, 3.5, .25, 3.5, 1, .25]);
        await close(tester, controller);
      },
    );

    testWidgets('$layout disables speed tap and long press when not ready', (
      tester,
    ) async {
      final controller = TestController();
      for (final state in [
        LumioPlayerState(speed: 3),
        LumioPlayerState(initialized: true, transitioning: true, speed: 3),
        LumioPlayerState(
          initialized: true,
          speed: 3,
          error: LumioPlayerError(code: 'test', message: 'Failure'),
        ),
      ]) {
        controller.value = state;
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(layout: layout),
          ),
        );
        final speed = find.byTooltip('Playback speed');
        final button = tester.widget<TextButton>(
          find.descendant(of: speed, matching: find.byType(TextButton)),
        );
        expect(button.onPressed, isNull);
        expect(button.onLongPress, isNull);
        await tester.tap(speed);
        await tester.pump();
        await tester.longPress(speed);
        await tester.pump();
        expect(controller.value.speed, 3);
        expect(controller.speeds, isEmpty);
      }
      await close(tester, controller);
    });

    testWidgets('$layout compact reveal preserves speed cycling', (
      tester,
    ) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          playing: true,
          duration: Duration(minutes: 2),
        );
      await tester.pumpWidget(
        host(
          controller,
          configuration: LumioControlsConfiguration(
            layout: layout,
            compact: true,
            compactDelay: const Duration(seconds: 1),
          ),
        ),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsOneWidget,
      );
      expect(find.byTooltip('Playback speed'), findsNothing);
      await tester.tapAt(
        tester
                .getRect(find.byKey(const ValueKey('lumio-gesture-surface')))
                .topCenter +
            const Offset(0, 20),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsNothing,
      );
      expect(find.text('1x'), findsOneWidget);
      expect(controller.speeds, isEmpty);
      await tester.tap(find.byTooltip('Playback speed'));
      await tester.pump();
      expect(find.text('2x'), findsOneWidget);
      expect(controller.speeds, [2]);
      await close(tester, controller);
    });

    testWidgets('$layout uses custom plain status labels', (tester) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          duration: Duration(minutes: 2),
        );
      await tester.pumpWidget(
        host(
          controller,
          configuration: LumioControlsConfiguration(
            layout: layout,
            playingLabel: 'Playing custom',
            pausedLabel: 'Paused custom',
            loadingLabel: 'Loading custom',
          ),
        ),
      );
      expect(find.text('Paused custom'), findsOneWidget);
      expect(find.text('PAUSADO'), findsNothing);
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(find.text('Playing custom'), findsOneWidget);
      expect(find.text('Paused custom'), findsNothing);
      expect(find.text('REPRODUZINDO'), findsNothing);
      controller.value = controller.value.copyWith(buffering: true);
      await tester.pump();
      expect(find.text('Loading custom'), findsOneWidget);
      expect(find.text('Playing custom'), findsNothing);
      expect(find.text('CARREGANDO'), findsNothing);
      controller.value = controller.value.copyWith(buffering: false);
      await tester.pump();
      await tester.tap(find.byTooltip('Pause'));
      await tester.pump();
      expect(find.text('Paused custom'), findsOneWidget);
      await close(tester, controller);
    });
  }

  testWidgets(
    'custom live label also supplies opt-in time and stays informational',
    (tester) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          live: true,
          position: Duration(seconds: 38),
        );
      for (final showLiveButton in [true, false]) {
        for (final showLiveTime in [false, true]) {
          await tester.pumpWidget(
            host(
              controller,
              configuration: LumioControlsConfiguration(
                liveLabel: 'Live custom',
                showLiveButton: showLiveButton,
                showLiveTime: showLiveTime,
              ),
            ),
          );
          final label = find.text(
            showLiveTime ? 'Live custom · 0:38' : 'Live custom',
          );
          expect(label, findsOneWidget);
          expect(tester.widget<Text>(label).style?.fontWeight, FontWeight.bold);
          expect(find.textContaining('AO VIVO'), findsNothing);
          expect(find.textContaining('LIVE'), findsNothing);
          expect(find.byKey(const ValueKey('lumio-live-dot')), findsNothing);
          expect(find.byTooltip('Return to live'), findsNothing);
          expect(
            find.ancestor(of: label, matching: find.byType(InkWell)),
            findsNothing,
          );
          await tester.tap(label);
          await tester.pump();
          expect(controller.liveSeeks, 0);
        }
      }
      await close(tester, controller);
    },
  );

  for (final width in [320.0, 360.0, 390.0]) {
    for (final speed in [1.0, 1.5, 4.0]) {
      testWidgets(
        'complete eight playlist actions share one row at ${width}px/$speed',
        (tester) async {
          final controller = TestController()
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
              initialized: true,
              duration: const Duration(minutes: 2),
              speed: speed,
            );
          await tester.pumpWidget(
            host(
              controller,
              width: width,
              configuration: const LumioControlsConfiguration(
                layout: LumioControlsLayout.complete,
                showVolumeSlider: true,
              ),
            ),
          );
          final row = tester.getRect(
            find.byKey(const ValueKey('lumio-complete-layout')),
          );
          final tooltips = [
            'Play',
            'Seek backward',
            'Seek forward',
            'Mute',
            'Playback speed',
            'Previous item',
            'Next item',
            'Fullscreen',
          ];
          final rects = <Rect>[];
          for (final tooltip in tooltips) {
            final finder = find.byTooltip(tooltip);
            expect(finder, findsOneWidget);
            expect(finder.hitTestable(), findsOneWidget);
            final rect = tester.getRect(finder);
            rects.add(rect);
            expect(rect.width, inInclusiveRange(32, 40));
            expect(rect.height, inInclusiveRange(32, 40));
            expect(rect.left, greaterThanOrEqualTo(row.left));
            expect(rect.right, lessThanOrEqualTo(row.right));
            expect(rect.center.dy, closeTo(rects.first.center.dy, .1));
            final icons = find.descendant(
              of: finder,
              matching: find.byType(Icon),
            );
            for (final element in icons.evaluate()) {
              final icon = element.widget as Icon;
              expect(
                icon.size ?? IconTheme.of(element).size!,
                lessThanOrEqualTo(24),
              );
            }
          }
          for (var i = 1; i < rects.length; i++) {
            expect(rects[i].left, greaterThanOrEqualTo(rects[i - 1].right));
          }
          expect(rects.last.right, closeTo(row.right, .1));
          expect(
            find.text(
              speed == 1.5
                  ? '1.5x'
                  : speed == 4
                  ? '4x'
                  : '1x',
            ),
            findsOneWidget,
          );
          final volume = tester.getRect(
            find.byKey(const ValueKey('lumio-volume')),
          );
          expect(volume.top, greaterThanOrEqualTo(row.bottom));
          expect(tester.takeException(), isNull);
          await close(tester, controller);
        },
      );
    }
  }

  testWidgets(
    'extremely narrow complete actions scroll horizontally with fullscreen pinned',
    (tester) async {
      final controller = TestController()
        ..testPlaylist = LumioPlaylist([
          for (final name in ['one', 'two'])
            LumioPlaylistItem(
              source: LumioSource.network(
                Uri.parse('https://example.com/$name.mp4'),
              ),
            ),
        ])
        ..value = LumioPlayerState(
          initialized: true,
          duration: Duration(minutes: 2),
          speed: 4,
        );
      await tester.pumpWidget(host(controller, width: 180));
      final rowFinder = find.byKey(const ValueKey('lumio-complete-layout'));
      final scroller = find.descendant(
        of: rowFinder,
        matching: find.byType(SingleChildScrollView),
      );
      expect(scroller, findsOneWidget);
      expect(
        tester.widget<SingleChildScrollView>(scroller).scrollDirection,
        Axis.horizontal,
      );
      expect(
        find.descendant(of: rowFinder, matching: find.byType(Wrap)),
        findsNothing,
      );
      final fullscreen = tester.getRect(find.byTooltip('Fullscreen'));
      final play = tester.getRect(find.byTooltip('Play'));
      final next = find.byTooltip('Next item');
      expect(tester.getRect(next).center.dy, closeTo(play.center.dy, .1));
      expect(
        tester.getRect(find.byTooltip('Playback speed')).center.dy,
        closeTo(play.center.dy, .1),
      );
      await tester.drag(scroller, const Offset(-300, 0));
      await tester.pumpAndSettle();
      expect(tester.getRect(find.byTooltip('Fullscreen')), fullscreen);
      expect(fullscreen.right, closeTo(tester.getRect(rowFinder).right, .1));
      expect(next.hitTestable(), findsOneWidget);
      await tester.tap(next);
      await tester.pump();
      expect(controller.playlistIndex, 1);
      expect(tester.takeException(), isNull);
      await close(tester, controller);
    },
  );

  for (final placement in LumioControlsPlacement.values) {
    for (final color in [
      Colors.black,
      const Color(0xFF2468AC),
      const Color(0x802468AC),
    ]) {
      testWidgets(
        '$placement preserves background RGB and scales only overlay alpha for $color',
        (tester) async {
          final controller = TestController()
            ..value = LumioPlayerState(initialized: true, playing: true);
          await tester.pumpWidget(
            host(
              controller,
              configuration: LumioControlsConfiguration(
                placement: placement,
                compact: true,
                backgroundColor: color,
              ),
            ),
          );
          final expected = placement == LumioControlsPlacement.overlay
              ? color.withValues(alpha: color.a * .65)
              : color;
          final material = find
              .descendant(
                of: find.byType(LumioPlayerControls),
                matching: find.byType(Material),
              )
              .first;
          expect(tester.widget<Material>(material).color, expected);
          await tester.pump(const Duration(seconds: 5));
          expect(
            find.byKey(const ValueKey('lumio-compact-controls')),
            findsOneWidget,
          );
          expect(tester.widget<Material>(material).color, expected);
          await close(tester, controller);
        },
      );
    }

    for (final videoLayout in LumioVideoLayout.values) {
      testWidgets(
        '$placement controls preserve $videoLayout viewport geometry',
        (tester) async {
          final controller = TestController()
            ..value = LumioPlayerState(
              initialized: true,
              duration: Duration(minutes: 2),
            );
          await tester.pumpWidget(
            host(
              controller,
              width: 360,
              height: videoLayout == LumioVideoLayout.expand ? 400 : null,
              videoLayout: videoLayout,
              aspectRatio: 2,
              configuration: LumioControlsConfiguration(placement: placement),
            ),
          );
          final view = tester.getRect(find.byType(LumioPlayerView));
          final surface = tester.getRect(
            find.byKey(const ValueKey('lumio-gesture-surface')),
          );
          final controls = tester.getRect(find.byType(LumioPlayerControls));
          final overlay = find.byKey(const ValueKey('lumio-controls-overlay'));
          final below = find.byKey(const ValueKey('lumio-controls-below'));
          expect(surface.width, closeTo(360, .1));
          if (placement == LumioControlsPlacement.overlay) {
            expect(overlay, findsOneWidget);
            expect(below, findsNothing);
            final positioned = tester.widget<Positioned>(overlay);
            expect(positioned.bottom, 0);
            expect(positioned.left, 0);
            expect(positioned.right, 0);
            expect(surface, view);
            expect(controls.bottom, closeTo(surface.bottom, .1));
            expect(controls.left, closeTo(surface.left, .1));
            expect(controls.right, closeTo(surface.right, .1));
            expect(
              surface.height,
              closeTo(videoLayout == LumioVideoLayout.expand ? 400 : 180, .1),
            );
          } else {
            expect(below, findsOneWidget);
            expect(overlay, findsNothing);
            expect(controls.top, closeTo(surface.bottom, .1));
            expect(view.height, closeTo(surface.height + controls.height, .1));
            expect(
              surface.height,
              closeTo(
                videoLayout == LumioVideoLayout.expand
                    ? 400 - controls.height
                    : 180,
                .1,
              ),
            );
          }
          expect(
            find.byKey(const ValueKey('lumio-surface-transform')),
            findsOneWidget,
          );
          expect(tester.takeException(), isNull);
          await close(tester, controller);
        },
      );
    }

    testWidgets(
      '$placement control hit tests never trigger media seek or hold',
      (tester) async {
        final controller = TestController()
          ..value = LumioPlayerState(
            initialized: true,
            duration: Duration(minutes: 2),
          );
        await tester.pumpWidget(
          host(
            controller,
            width: 390,
            configuration: LumioControlsConfiguration(placement: placement),
          ),
        );
        final mute = find.byTooltip('Mute');
        await tester.tap(mute);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tap(find.byTooltip('Unmute'));
        await tester.pump(const Duration(milliseconds: 350));
        expect(controller.value.volume, 1);
        expect(controller.sought, isNull);
        expect(controller.speeds, isEmpty);
        final gesture = await tester.startGesture(
          tester.getCenter(find.byTooltip('Mute')),
        );
        await tester.pump(const Duration(milliseconds: 700));
        expect(controller.speeds, isEmpty);
        await gesture.up();
        await tester.pump();
        expect(controller.sought, isNull);
        expect(controller.liveSeeks, 0);
        await close(tester, controller);
      },
    );

    testWidgets('$placement survives compact mode and built-in fullscreen', (
      tester,
    ) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          playing: true,
          duration: Duration(minutes: 2),
        );
      await tester.pumpWidget(
        host(
          controller,
          width: 390,
          configuration: LumioControlsConfiguration(
            placement: placement,
            compact: true,
            compactDelay: const Duration(seconds: 1),
          ),
        ),
      );
      final wrapper = find.byKey(
        ValueKey(
          placement == LumioControlsPlacement.overlay
              ? 'lumio-controls-overlay'
              : 'lumio-controls-below',
        ),
      );
      final initialSurface = tester.getRect(
        find.byKey(const ValueKey('lumio-gesture-surface')),
      );
      await tester.pump(const Duration(seconds: 2));
      expect(wrapper, findsOneWidget);
      expect(
        tester
            .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
            .compacted,
        true,
      );
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsOneWidget,
      );
      expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
      if (placement == LumioControlsPlacement.overlay) {
        expect(
          tester.getRect(find.byKey(const ValueKey('lumio-gesture-surface'))),
          initialSurface,
        );
      }
      await tester.tapAt(
        tester
                .getRect(find.byKey(const ValueKey('lumio-gesture-surface')))
                .topCenter +
            const Offset(0, 20),
      );
      await tester.pump(const Duration(milliseconds: 350));
      expect(
        tester
            .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
            .compacted,
        false,
      );
      expect(
        find.byKey(const ValueKey('lumio-compact-progress')),
        findsNothing,
      );
      expect(find.byKey(const ValueKey('lumio-progress')), findsOneWidget);
      controller.value = controller.value.copyWith(playing: false);
      await tester.pump();
      await tester.tap(find.byTooltip('Fullscreen'));
      await tester.pumpAndSettle();
      expect(wrapper, findsOneWidget);
      expect(
        tester
            .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
            .configuration
            .placement,
        placement,
      );
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      final surface = tester.getRect(
        find.byKey(const ValueKey('lumio-gesture-surface')),
      );
      final controls = tester.getRect(find.byType(LumioPlayerControls));
      if (placement == LumioControlsPlacement.overlay) {
        expect(controls.bottom, closeTo(surface.bottom, .1));
      } else {
        expect(controls.top, closeTo(surface.bottom, .1));
      }
      await tester.tap(find.byTooltip('Exit fullscreen'));
      await tester.pumpAndSettle();
      expect(wrapper, findsOneWidget);
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      await close(tester, controller);
    });
  }

  for (final width in [200.0, 600.0]) {
    for (final layout in LumioControlsLayout.values) {
      testWidgets('$layout composition and geometry at ${width}px', (
        tester,
      ) async {
        final controller = TestController()
          ..value = LumioPlayerState(
            initialized: true,
            position: Duration(seconds: 4),
            duration: Duration(seconds: 77),
          );
        await tester.pumpWidget(
          host(
            controller,
            width: width,
            configuration: LumioControlsConfiguration(layout: layout),
          ),
        );
        final controls = tester.getRect(find.byType(LumioPlayerControls));
        if (layout == LumioControlsLayout.live) {
          expect(find.byKey(const ValueKey('lumio-live-dot')), findsNothing);
          expect(find.byTooltip('Return to live'), findsNothing);
          final label = tester.getRect(find.text('AO VIVO'));
          final volume = tester.getRect(find.byTooltip('Mute'));
          final fullscreen = tester.getRect(find.byTooltip('Fullscreen'));
          expect(label.left, greaterThanOrEqualTo(controls.left));
          expect(label.right, lessThanOrEqualTo(volume.left));
          expect(volume.right, lessThanOrEqualTo(fullscreen.left));
          expect(volume.center.dy, closeTo(fullscreen.center.dy, .1));
          expect(fullscreen.right, lessThanOrEqualTo(controls.right));
          expect(find.byTooltip('Play'), findsNothing);
          expect(find.byTooltip('Seek forward'), findsNothing);
          expect(find.byTooltip('Playback speed'), findsNothing);
          expect(find.byType(Slider), findsNothing);
        } else {
          final slider = tester.getRect(
            find.byKey(const ValueKey('lumio-progress')),
          );
          final metadata = tester.getRect(
            find.byKey(const ValueKey('lumio-progress-row')),
          );
          final time = tester.getRect(
            find.byKey(const ValueKey('lumio-progress-time')),
          );
          final status = tester.getRect(find.text('PAUSADO'));
          final play = tester.getRect(find.byTooltip('Play'));
          final speed = tester.getRect(find.byTooltip('Playback speed'));
          expect(metadata.top - slider.bottom, closeTo(8, .1));
          expect(slider.left, closeTo(metadata.left, .1));
          expect(slider.right, closeTo(metadata.right, .1));
          expect(status.center.dy, closeTo(time.center.dy, .1));
          expect(time.left, greaterThanOrEqualTo(status.right));
          expect(time.right, slider.right);
          expect(status.left, slider.left);
          expect(time.width, lessThanOrEqualTo(slider.width * .5));
          expect(find.text('1x'), findsOneWidget);
          if (layout == LumioControlsLayout.simplified) {
            expect(play.right, lessThanOrEqualTo(slider.left));
            expect(slider.right, lessThanOrEqualTo(speed.left));
            expect(play.center.dy, closeTo(speed.center.dy, .1));
            expect(find.byTooltip('Mute'), findsNothing);
            expect(find.byTooltip('Seek backward'), findsNothing);
            expect(find.byTooltip('Seek forward'), findsNothing);
            expect(find.byTooltip('Fullscreen'), findsNothing);
          } else {
            final row = tester.getRect(
              find.byKey(const ValueKey('lumio-complete-layout')),
            );
            final fullscreen = tester.getRect(
              find.ancestor(
                of: find.byTooltip('Fullscreen'),
                matching: find.byType(IconButton),
              ),
            );
            expect(slider.left, closeTo(row.left, .1));
            expect(slider.right, closeTo(row.right, .1));
            expect(row.top, greaterThanOrEqualTo(metadata.bottom));
            expect(fullscreen.right, closeTo(row.right, .1));
            final actions = [
              play,
              tester.getRect(find.byTooltip('Seek backward')),
              tester.getRect(find.byTooltip('Seek forward')),
              tester.getRect(find.byTooltip('Mute')),
              speed,
            ];
            for (final action in actions) {
              expect(action.left, greaterThanOrEqualTo(row.left));
              if (width >= 400) {
                expect(action.right, lessThanOrEqualTo(fullscreen.left));
              }
              expect(action.center.dy, closeTo(fullscreen.center.dy, .1));
              expect(action.top, greaterThanOrEqualTo(row.top));
              expect(action.bottom, lessThanOrEqualTo(row.bottom));
            }
            if (width >= 400) {
              for (var i = 1; i < actions.length; i++) {
                expect(
                  actions[i].left,
                  greaterThanOrEqualTo(actions[i - 1].right),
                );
                expect(actions[i].center.dy, closeTo(play.center.dy, .1));
              }
            }
            expect(speed.center.dy, closeTo(play.center.dy, .1));
          }
        }
        expect(tester.takeException(), isNull);
        await close(tester, controller);
      });
    }

    for (final layout in [
      LumioControlsLayout.complete,
      LumioControlsLayout.simplified,
    ]) {
      testWidgets('$layout optional playlist navigation at ${width}px', (
        tester,
      ) async {
        final controller = TestController()
          ..value = LumioPlayerState(
            initialized: true,
            duration: Duration(minutes: 1),
          );
        final configuration = LumioControlsConfiguration(layout: layout);
        await tester.pumpWidget(
          host(controller, width: width, configuration: configuration),
        );
        expect(find.byTooltip('Previous item'), findsNothing);
        expect(find.byTooltip('Next item'), findsNothing);
        controller.testPlaylist = LumioPlaylist([
          LumioPlaylistItem(
            source: LumioSource.network(
              Uri.parse('https://example.com/one.mp4'),
            ),
          ),
          LumioPlaylistItem(
            source: LumioSource.network(
              Uri.parse('https://example.com/two.mp4'),
            ),
          ),
        ]);
        controller.notifyListeners();
        await tester.pump();
        final previous = find.byTooltip('Previous item');
        final next = find.byTooltip('Next item');
        if (layout == LumioControlsLayout.simplified) {
          for (final action in LumioSimplifiedControl.values) {
            for (final showNavigation in [true, false]) {
              await tester.pumpWidget(
                host(
                  controller,
                  width: width,
                  configuration: LumioControlsConfiguration(
                    layout: layout,
                    simplifiedControl: action,
                    showPlaylistNavigation: showNavigation,
                    showPreviousItem: true,
                    showNextItem: true,
                  ),
                ),
              );
              expect(previous, findsNothing);
              expect(next, findsNothing);
              expect(find.byTooltip('Play'), findsOneWidget);
              expect(
                find.byKey(const ValueKey('lumio-progress')),
                findsOneWidget,
              );
              expect(tester.takeException(), isNull);
            }
          }
          await close(tester, controller);
          return;
        }
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(of: previous, matching: find.byType(IconButton)),
              )
              .onPressed,
          isNull,
        );
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(of: next, matching: find.byType(IconButton)),
              )
              .onPressed,
          isNotNull,
        );
        {
          final primary = tester.getRect(
            find.byKey(const ValueKey('lumio-complete-layout')),
          );
          expect(
            tester.getRect(next).bottom,
            lessThanOrEqualTo(primary.bottom),
          );
          if (width >= 400) {
            expect(
              tester.getRect(previous).left,
              greaterThanOrEqualTo(
                tester.getRect(find.byTooltip('Playback speed')).right,
              ),
            );
            expect(
              tester.getRect(next).right,
              lessThanOrEqualTo(
                tester.getRect(find.byTooltip('Fullscreen')).left,
              ),
            );
          }
        }
        await tester.ensureVisible(next);
        await tester.pump();
        await tester.tap(next);
        await tester.pump();
        expect(controller.playlistIndex, 1);
        expect(
          tester
              .widget<IconButton>(
                find.ancestor(of: next, matching: find.byType(IconButton)),
              )
              .onPressed,
          isNull,
        );
        await tester.ensureVisible(previous);
        await tester.pump();
        await tester.tap(previous);
        await tester.pump();
        expect(controller.playlistIndex, 0);
        for (final showPrevious in [false, true]) {
          for (final showNext in [false, true]) {
            for (final showNavigation in [false, true]) {
              await tester.pumpWidget(
                host(
                  controller,
                  width: width,
                  configuration: LumioControlsConfiguration(
                    layout: layout,
                    showPlaylistNavigation: showNavigation,
                    showPreviousItem: showPrevious,
                    showNextItem: showNext,
                  ),
                ),
              );
              expect(
                previous,
                showNavigation && showPrevious ? findsOneWidget : findsNothing,
              );
              expect(
                next,
                showNavigation && showNext ? findsOneWidget : findsNothing,
              );
              expect(find.byTooltip('Play'), findsOneWidget);
              expect(
                find.byKey(const ValueKey('lumio-progress')),
                findsOneWidget,
              );
              expect(controller.playlistIndex, 0);
              expect(tester.takeException(), isNull);
            }
          }
        }
        await tester.pumpWidget(
          host(
            controller,
            width: width,
            configuration: LumioControlsConfiguration(
              layout: layout,
              showPlaylistNavigation: false,
            ),
          ),
        );
        expect(previous, findsNothing);
        expect(next, findsNothing);
        expect(find.byTooltip('Play'), findsOneWidget);
        controller.value = controller.value.copyWith(live: true);
        await tester.pumpWidget(
          host(controller, width: width, configuration: configuration),
        );
        expect(find.text('AO VIVO'), findsOneWidget);
        expect(previous, findsNothing);
        expect(next, findsNothing);
        expect(tester.takeException(), isNull);
        await close(tester, controller);
      });
    }
  }

  for (final width in [200.0, 600.0]) {
    for (final action in LumioSimplifiedControl.values) {
      testWidgets(
        'simplified $action has one trailing action and central progress at ${width}px',
        (tester) async {
          final controller = TestController()
            ..value = LumioPlayerState(
              initialized: true,
              position: Duration(seconds: 4),
              duration: Duration(seconds: 77),
            );
          await tester.pumpWidget(
            host(
              controller,
              width: width,
              title: 'Simplified title',
              configuration: LumioControlsConfiguration(
                layout: LumioControlsLayout.simplified,
                simplifiedControl: action,
                showVolumeSlider: true,
              ),
            ),
          );
          final speed = action == LumioSimplifiedControl.speed;
          final actionFinder = find.byTooltip(
            speed ? 'Playback speed' : 'Mute',
          );
          expect(actionFinder, findsOneWidget);
          expect(
            find.byTooltip(speed ? 'Mute' : 'Playback speed'),
            findsNothing,
          );
          expect(find.byTooltip('Seek backward'), findsNothing);
          expect(find.byTooltip('Seek forward'), findsNothing);
          expect(find.byIcon(Icons.fullscreen), findsNothing);
          expect(find.byKey(const ValueKey('lumio-volume')), findsNothing);
          expect(find.text('Simplified title'), findsOneWidget);
          expect(find.text('0:04 / 1:17'), findsOneWidget);
          final play = tester.getRect(find.byTooltip('Play'));
          final trailing = tester.getRect(actionFinder);
          final slider = tester.getRect(
            find.byKey(const ValueKey('lumio-progress')),
          );
          final status = tester.getRect(find.text('PAUSADO'));
          final time = tester.getRect(
            find.byKey(const ValueKey('lumio-progress-time')),
          );
          final metadata = tester.getRect(
            find.byKey(const ValueKey('lumio-progress-row')),
          );
          expect(slider.left - play.right, closeTo(8, .1));
          expect(trailing.left - slider.right, closeTo(8, .1));
          expect(slider.width, closeTo(metadata.width, 0.1));
          expect(slider.left, closeTo(metadata.left, 0.1));
          expect(metadata.top - slider.bottom, closeTo(8, .1));
          expect(status.left, slider.left);
          expect(time.left, greaterThanOrEqualTo(status.right));
          expect(time.right, slider.right);
          expect(time.width, lessThanOrEqualTo(slider.width * .5));
          expect(status.center.dy, closeTo(time.center.dy, 0.1));
          expect(play.center.dy, closeTo(trailing.center.dy, 0.1));
          expect(play.center.dy, inInclusiveRange(slider.top, metadata.bottom));
          await tester.tap(find.byTooltip('Play'));
          await tester.pump();
          expect(find.text('REPRODUZINDO'), findsOneWidget);
          expect(find.text('PAUSADO'), findsNothing);
          if (speed) {
            expect(find.text('1x'), findsOneWidget);
            await tester.tap(actionFinder);
            await tester.pump();
            expect(controller.value.speed, 2);
            expect(controller.speeds, [2]);
            expect(find.byType(PopupMenuItem<double>), findsNothing);
            expect(find.text('1x'), findsNothing);
            expect(find.text('1.5x'), findsNothing);
            final indicator = tester.widget<Text>(find.text('2x'));
            expect(indicator.style?.fontSize, 16);
          } else {
            await tester.tap(actionFinder);
            await tester.pump();
            expect(controller.value.volume, 0);
            expect(find.byTooltip('Unmute'), findsOneWidget);
          }
          await tester.pumpWidget(
            host(
              controller,
              configuration: LumioControlsConfiguration(
                layout: LumioControlsLayout.simplified,
                simplifiedControl: action,
                showSpeed: !speed,
                showVolume: speed,
              ),
            ),
          );
          expect(find.byTooltip('Playback speed'), findsNothing);
          expect(find.byTooltip('Mute'), findsNothing);
          expect(find.byTooltip('Unmute'), findsNothing);
          expect(find.byTooltip('Pause'), findsOneWidget);
          expect(find.byKey(const ValueKey('lumio-progress')), findsOneWidget);
          expect(tester.takeException(), isNull);
          await close(tester, controller);
        },
      );
    }
  }

  testWidgets(
    'live status is bold informational text without playback controls',
    (tester) async {
      final controller = TestController()
        ..value = LumioPlayerState(initialized: true, live: true);
      await tester.pumpWidget(host(controller, title: 'Live title'));
      expect(find.text('Live title'), findsOneWidget);
      expect(find.text('AO VIVO'), findsOneWidget);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      for (final tooltip in [
        'Play',
        'Pause',
        'Seek backward',
        'Seek forward',
        'Playback speed',
      ]) {
        expect(find.byTooltip(tooltip), findsNothing);
      }
      expect(find.byType(Slider), findsNothing);
      final status = tester.getRect(find.text('AO VIVO'));
      final volume = tester.getRect(find.byTooltip('Mute'));
      final fullscreen = tester.getRect(find.byIcon(Icons.fullscreen));
      expect(status.right, lessThanOrEqualTo(volume.left));
      expect(volume.right, lessThanOrEqualTo(fullscreen.left));
      expect(status.center.dy, closeTo(volume.center.dy, 0.1));
      final label = find.text('AO VIVO');
      expect(tester.widget<Text>(label).style?.fontWeight, FontWeight.bold);
      expect(find.byKey(const ValueKey('lumio-live-dot')), findsNothing);
      expect(find.byTooltip('Return to live'), findsNothing);
      expect(
        find.ancestor(of: label, matching: find.byType(InkWell)),
        findsNothing,
      );
      final gestures = find.ancestor(
        of: label,
        matching: find.byType(GestureDetector),
      );
      for (final gesture in tester.widgetList<GestureDetector>(gestures)) {
        expect(gesture.onTap, isNull);
      }
      final originalState = controller.value;
      await tester.tap(label);
      await tester.pump();
      expect(controller.liveSeeks, 0);
      expect(controller.sought, isNull);
      expect(controller.speeds, isEmpty);
      expect(controller.value, same(originalState));
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(
            showLiveButton: false,
          ),
        ),
      );
      expect(find.text('AO VIVO'), findsOneWidget);
      expect(find.byTooltip('Return to live'), findsNothing);
      await tester.tap(find.text('AO VIVO'));
      await tester.pump();
      expect(controller.liveSeeks, 0);
      expect(controller.value, same(originalState));
      await tester.pumpWidget(
        host(
          controller,
          configuration: const LumioControlsConfiguration(showStatus: false),
        ),
      );
      expect(find.text('AO VIVO'), findsNothing);
      expect(find.byTooltip('Return to live'), findsNothing);
      expect(find.byTooltip('Mute'), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      await close(tester, controller);
    },
  );

  for (final mode in [LumioPlaybackMode.video, LumioPlaybackMode.live]) {
    for (final layout in LumioControlsLayout.values) {
      testWidgets('$mode selects live over requested $layout', (tester) async {
        final controller =
            TestController(configuration: LumioPlayerConfiguration(mode: mode))
              ..value = LumioPlayerState(
                initialized: true,
                live: mode == LumioPlaybackMode.video,
                duration: const Duration(minutes: 1),
              );
        await tester.pumpWidget(
          host(
            controller,
            configuration: LumioControlsConfiguration(layout: layout),
          ),
        );
        expect(find.text('AO VIVO'), findsOneWidget);
        expect(find.byTooltip('Play'), findsNothing);
        expect(find.byTooltip('Playback speed'), findsNothing);
        expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
        expect(tester.takeException(), isNull);
        await close(tester, controller);
      });
    }
  }

  testWidgets('explicit live layout also applies before live detection', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          layout: LumioControlsLayout.live,
        ),
      ),
    );
    expect(find.text('AO VIVO'), findsOneWidget);
    expect(find.byTooltip('Play'), findsNothing);
    expect(find.byTooltip('Playback speed'), findsNothing);
    expect(find.byType(Slider), findsNothing);
    await close(tester, controller);
  });

  testWidgets('standalone fullscreen requires a callback and honors its flag', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    var toggles = 0;
    Widget standalone({
      VoidCallback? callback,
      bool fullscreen = false,
      bool showFullscreen = true,
    }) => MaterialApp(
      home: Scaffold(
        body: LumioPlayerControls(
          controller: controller,
          onToggleFullscreen: callback,
          isFullscreen: fullscreen,
          configuration: LumioControlsConfiguration(
            showFullscreen: showFullscreen,
          ),
        ),
      ),
    );
    await tester.pumpWidget(standalone());
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    await tester.pumpWidget(standalone(callback: () => toggles++));
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pump();
    expect(toggles, 1);
    await tester.pumpWidget(
      standalone(callback: () => toggles++, fullscreen: true),
    );
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(toggles, 2);
    await tester.pumpWidget(
      standalone(callback: () => toggles++, showFullscreen: false),
    );
    expect(find.byIcon(Icons.fullscreen), findsNothing);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
    await close(tester, controller);
  });

  testWidgets('view delegates fullscreen to the host when supplied', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    var toggles = 0;
    await tester.pumpWidget(
      host(controller, onToggleFullscreen: () => toggles++),
    );
    await tester.tap(find.byIcon(Icons.fullscreen));
    await tester.pumpAndSettle();
    expect(toggles, 1);
    expect(find.byType(Texture), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen_exit), findsNothing);
    await tester.pumpWidget(
      host(controller, onToggleFullscreen: () => toggles++, isFullscreen: true),
    );
    expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
    await tester.tap(find.byIcon(Icons.fullscreen_exit));
    await tester.pump();
    expect(toggles, 2);
    await close(tester, controller);
  });

  testWidgets(
    'built-in fullscreen route keeps a single surface and returns inline',
    (tester) async {
      final controller = TestController()
        ..value = LumioPlayerState(
          initialized: true,
          position: Duration(seconds: 12),
          duration: Duration(minutes: 2),
          speed: 1.5,
          volume: .4,
        );
      final originalState = controller.value;
      await tester.pumpWidget(host(controller));
      final inline = tester.getRect(find.byType(Texture));
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pump();
      expect(
        find.byType(Texture, skipOffstage: false).evaluate().length,
        lessThanOrEqualTo(1),
      );
      await tester.pumpAndSettle();
      expect(
        tester
            .widget<LumioPlayerControls>(find.byType(LumioPlayerControls))
            .controller,
        same(controller),
      );
      expect(controller.value, same(originalState));
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      expect(
        tester.getRect(find.byType(Texture)).width,
        greaterThan(inline.width),
      );
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      await tester.tap(find.byIcon(Icons.fullscreen_exit));
      await tester.pump();
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen, skipOffstage: false), findsNothing);
      expect(controller.value, same(originalState));
      await tester.pumpAndSettle();
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      expect(
        tester.getRect(find.byType(Texture)).width,
        closeTo(inline.width, 0.1),
      );
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      expect(controller.value, same(originalState));
      await tester.tap(find.byIcon(Icons.fullscreen));
      await tester.pumpAndSettle();
      tester.state<NavigatorState>(find.byType(Navigator)).pop();
      await tester.pump();
      await tester.pump(const Duration(milliseconds: 100));
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen_exit), findsOneWidget);
      expect(controller.value, same(originalState));
      await tester.pumpAndSettle();
      expect(find.byType(Texture, skipOffstage: false), findsOneWidget);
      expect(find.byIcon(Icons.fullscreen), findsOneWidget);
      expect(controller.value, same(originalState));
      await tester.tap(find.byTooltip('Play'));
      await tester.pump();
      expect(controller.value.playing, true);
      await close(tester, controller);
    },
  );

  for (final width in [180.0, 200.0]) {
    for (final layout in LumioControlsLayout.values) {
      for (final action in LumioSimplifiedControl.values) {
        testWidgets(
          '$layout/$action fits ${width}px with title and secondary controls',
          (tester) async {
            final controller = TestController()
              ..value = LumioPlayerState(
                initialized: true,
                duration: Duration(minutes: 2),
                error: LumioPlayerError(code: 'test', message: 'Failure'),
              );
            await tester.pumpWidget(
              host(
                controller,
                width: width,
                title: 'A long title that should truncate in every layout',
                configuration: LumioControlsConfiguration(
                  layout: layout,
                  simplifiedControl: action,
                  showSettings: true,
                ),
              ),
            );
            expect(find.textContaining('A long title'), findsOneWidget);
            expect(find.byTooltip('Playback engine'), findsOneWidget);
            expect(find.byTooltip('Retry'), findsOneWidget);
            if (layout == LumioControlsLayout.live) {
              expect(find.text('AO VIVO'), findsOneWidget);
              expect(find.byType(Slider), findsNothing);
            } else {
              expect(
                find.byKey(const ValueKey('lumio-progress')),
                findsOneWidget,
              );
              expect(find.byTooltip('Play'), findsOneWidget);
            }
            expect(tester.takeException(), isNull);
            await close(tester, controller);
          },
        );
      }
    }
  }

  testWidgets('complete metadata is below the full-width progress slider', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(
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
    final metadata = tester.getRect(
      find.byKey(const ValueKey('lumio-progress-row')),
    );
    expect(metadata.top - slider.bottom, closeTo(8, .1));
    final status = tester.getRect(find.text('PAUSADO'));
    expect(status.center.dy, closeTo(time.center.dy, 0.1));
    expect(status.right, lessThanOrEqualTo(time.left));
    final row = tester.getRect(
      find.byKey(const ValueKey('lumio-progress-row')),
    );
    expect(time.right, slider.right);
    expect(status.left, slider.left);
    expect(time.width, lessThanOrEqualTo(slider.width * .5));
    expect(slider.left, closeTo(row.left, 0.1));
    expect(slider.right, closeTo(row.right, 0.1));
    final play = tester.getRect(find.byTooltip('Play'));
    final fullscreen = tester.getRect(find.byIcon(Icons.fullscreen));
    expect(play.top, greaterThanOrEqualTo(row.bottom));
    expect(
      fullscreen.center.dy,
      closeTo(
        tester
            .getRect(find.byKey(const ValueKey('lumio-complete-layout')))
            .center
            .dy,
        0.1,
      ),
    );
    expect(fullscreen.left, greaterThan(play.right));
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('progress fills the row when time is hidden', (tester) async {
    final controller = TestController()
      ..value = LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 2),
      );
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showTime: false),
      ),
    );
    final row = tester.getRect(
      find.byKey(const ValueKey('lumio-progress-row')),
    );
    final slider = tester.getRect(find.byKey(const ValueKey('lumio-progress')));
    expect(slider.left, row.left);
    expect(slider.right, row.right);
    expect(find.byKey(const ValueKey('lumio-progress-time')), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('playback engine selector can be explicitly enabled', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showSettings: true),
      ),
    );
    await tester.tap(find.byTooltip('Playback engine'));
    await tester.pumpAndSettle();
    expect(find.text('automatic'), findsOneWidget);
    expect(find.text('native'), findsOneWidget);
    expect(find.text('webview'), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('live time is opt-in and respects the time master switch', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(
        initialized: true,
        live: true,
        position: Duration(seconds: 38),
      );
    await tester.pumpWidget(host(controller));
    expect(find.text('AO VIVO · 0:38'), findsNothing);
    expect(find.byTooltip('Return to live'), findsNothing);
    expect(find.text('AO VIVO'), findsOneWidget);
    expect(find.byTooltip('Playback speed'), findsNothing);
    expect(find.text('1x'), findsNothing);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showLiveTime: true),
      ),
    );
    expect(find.text('AO VIVO · 0:38'), findsOneWidget);
    expect(find.text('AO VIVO'), findsNothing);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          showStatus: false,
          showLiveTime: true,
        ),
      ),
    );
    expect(find.text('AO VIVO · 0:38'), findsOneWidget);
    expect(
      tester.widget<Text>(find.text('AO VIVO · 0:38')).style?.fontWeight,
      FontWeight.bold,
    );
    expect(find.byKey(const ValueKey('lumio-live-dot')), findsNothing);
    expect(find.byTooltip('Return to live'), findsNothing);
    await tester.tap(find.text('AO VIVO · 0:38'));
    await tester.pump();
    expect(controller.liveSeeks, 0);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          showLiveTime: true,
          showTime: false,
        ),
      ),
    );
    expect(find.text('AO VIVO · 0:38'), findsNothing);
    expect(find.text('AO VIVO'), findsOneWidget);
    await close(tester, controller);
  });

  testWidgets('live configuration hides speed before live state is reported', (
    tester,
  ) async {
    final controller = TestController(
      configuration: const LumioPlayerConfiguration(
        mode: LumioPlaybackMode.live,
      ),
    )..value = LumioPlayerState(initialized: true);
    await tester.pumpWidget(host(controller));
    expect(find.text('AO VIVO'), findsOneWidget);
    expect(find.byTooltip('Play'), findsNothing);
    expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
    expect(find.byTooltip('Playback speed'), findsNothing);
    expect(find.text('1x'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('time remains available when progress is hidden', (tester) async {
    final controller = TestController()
      ..value = LumioPlayerState(
        initialized: true,
        duration: Duration(minutes: 1),
      );
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showProgress: false),
      ),
    );
    expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
    expect(find.text('PAUSADO'), findsOneWidget);
    expect(find.text('0:00 / 1:00'), findsOneWidget);
    await close(tester, controller);
  });

  test('configuration defaults and runtime validation', () {
    const defaults = LumioControlsConfiguration();
    defaults.validate();
    expect(defaults.playbackSpeeds, [1, 2, 3, 4]);
    expect(defaults.seekInterval, const Duration(seconds: 10));
    expect(defaults.holdSpeed, 2);
    expect(defaults.maxZoom, 4);
    expect(defaults.compact, false);
    expect(defaults.compactDelay, const Duration(seconds: 5));
    expect(defaults.layout, LumioControlsLayout.automatic);
    expect(defaults.placement, LumioControlsPlacement.below);
    expect(defaults.liveLabel, 'AO VIVO');
    expect(defaults.playingLabel, 'REPRODUZINDO');
    expect(defaults.pausedLabel, 'PAUSADO');
    expect(defaults.loadingLabel, 'CARREGANDO');
    expect(defaults.simplifiedControl, LumioSimplifiedControl.speed);
    expect(defaults.showStatus, true);
    expect(defaults.showFullscreen, true);
    expect(defaults.showVolume, true);
    expect(defaults.showVolumeSlider, false);
    expect(defaults.showPlaylistNavigation, true);
    expect(defaults.showPreviousItem, true);
    expect(defaults.showNextItem, true);
    expect(defaults.showSettings, false);
    expect(defaults.showLiveTime, false);
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
      ..value = LumioPlayerState(
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
    ]) {
      expect(find.byTooltip(tooltip), findsOneWidget);
    }
    expect(find.byKey(const ValueKey('lumio-progress')), findsOneWidget);
    expect(find.text('PAUSADO'), findsOneWidget);
    expect(find.text('1x'), findsOneWidget);
    expect(find.byIcon(Icons.fullscreen), findsOneWidget);
    expect(find.byKey(const ValueKey('lumio-volume')), findsNothing);
    expect(find.byTooltip('Playback engine'), findsNothing);
    expect(find.textContaining('A long broadcast'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });

  testWidgets('all switches off and master disable leave no chrome', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(
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
    expect(find.text('PAUSADO'), findsNothing);
    expect(find.text('REPRODUZINDO'), findsNothing);
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

  testWidgets(
    'initial loading, buffering and reopening share the same loader',
    (tester) async {
      final controller = TestController();
      await tester.pumpWidget(host(controller, controls: false));
      for (final state in [
        LumioPlayerState(buffering: true),
        LumioPlayerState(initialized: true, playing: true, buffering: true),
        LumioPlayerState(initialized: true, transitioning: true),
      ]) {
        controller.value = state;
        await tester.pump();
        final loader = find.byKey(const ValueKey('lumio-loading-indicator'));
        expect(loader, findsOneWidget);
        expect(tester.getSize(loader), const Size(48, 48));
        final spinner = find.descendant(
          of: loader,
          matching: find.byType(CircularProgressIndicator),
        );
        expect(tester.getSize(spinner), const Size(24, 24));
        final indicator = tester.widget<CircularProgressIndicator>(spinner);
        expect(indicator.color, Colors.white);
        expect(indicator.strokeWidth, 2.6);
        final background =
            tester
                    .widget<DecoratedBox>(
                      find.descendant(
                        of: loader,
                        matching: find.byType(DecoratedBox),
                      ),
                    )
                    .decoration
                as BoxDecoration;
        expect(background.shape, BoxShape.circle);
        expect(background.color, const Color(0x61000000));
      }
      controller.value = LumioPlayerState(initialized: true, playing: true);
      await tester.pump();
      expect(
        find.byKey(const ValueKey('lumio-loading-indicator')),
        findsNothing,
      );
      await close(tester, controller);
    },
  );

  testWidgets('individual switches remove only their own UI', (tester) async {
    final controller = TestController()
      ..value = LumioPlayerState(
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
      (
        const LumioControlsConfiguration(showStatus: false),
        find.text('PAUSADO'),
      ),
      (
        const LumioControlsConfiguration(showFullscreen: false),
        find.byIcon(Icons.fullscreen),
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
      await tester.pumpWidget(
        host(
          controller,
          title: 'Title',
          configuration: const LumioControlsConfiguration(showSettings: true),
        ),
      );
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
    expect(find.text('AO VIVO'), findsOneWidget);
    expect(find.textContaining('LIVE'), findsNothing);
    await close(tester, controller);
  });

  testWidgets('standalone speed-only controls use custom speeds', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
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
              showStatus: false,
              showFullscreen: false,
              playbackSpeeds: [.25, .75, 3.5],
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Slider), findsNothing);
    expect(find.byType(IconButton), findsNothing);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    expect(find.text('0.25x'), findsOneWidget);
    expect(find.text('2x'), findsNothing);
    expect(find.byType(PopupMenuItem<double>), findsNothing);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    expect(find.text('0.75x'), findsOneWidget);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    expect(find.text('3.5x'), findsOneWidget);
    expect(controller.value.speed, 3.5);
    expect(controller.speeds, [.25, .75, 3.5]);
    await close(tester, controller);
  });

  testWidgets('volume slider is exclusive to complete non-live controls', (
    tester,
  ) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    for (final live in [false, true]) {
      controller.value = controller.value.copyWith(live: live);
      for (final layout in LumioControlsLayout.values) {
        await tester.pumpWidget(
          host(
            controller,
            width: 600,
            configuration: LumioControlsConfiguration(
              layout: layout,
              simplifiedControl: LumioSimplifiedControl.volume,
              showVolumeSlider: true,
            ),
          ),
        );
        expect(
          find.byKey(const ValueKey('lumio-volume')),
          !live &&
                  (layout == LumioControlsLayout.automatic ||
                      layout == LumioControlsLayout.complete)
              ? findsOneWidget
              : findsNothing,
        );
        expect(find.byTooltip('Mute'), findsOneWidget);
        if (!live &&
            (layout == LumioControlsLayout.automatic ||
                layout == LumioControlsLayout.complete)) {
          final volume = tester.getRect(
            find.byKey(const ValueKey('lumio-volume')),
          );
          final primary = tester.getRect(
            find.byKey(const ValueKey('lumio-complete-layout')),
          );
          expect(volume.top, greaterThanOrEqualTo(primary.bottom));
        }
        expect(tester.takeException(), isNull);
      }
    }
    await close(tester, controller);
  });

  testWidgets('volume gain and mute-only capability', (tester) async {
    final controller = TestController()
      ..value = LumioPlayerState(initialized: true);
    await tester.pumpWidget(host(controller));
    expect(find.byKey(const ValueKey('lumio-volume')), findsNothing);
    expect(find.byTooltip('Mute'), findsOneWidget);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          showVolume: false,
          showVolumeSlider: true,
        ),
      ),
    );
    expect(find.byKey(const ValueKey('lumio-volume')), findsNothing);
    expect(find.byTooltip('Mute'), findsNothing);
    expect(find.byTooltip('Play'), findsOneWidget);
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(showVolumeSlider: true),
      ),
    );
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
      ..value = LumioPlayerState(
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
    controller.value = LumioPlayerState(
      initialized: true,
      duration: Duration(minutes: 2),
    );
    await tester.pumpWidget(host(controller));
    expect(find.byType(Texture), findsOneWidget);
    expect(find.text('PAUSADO'), findsOneWidget);
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(find.byTooltip('Pause'), findsOneWidget);
    expect(find.text('REPRODUZINDO'), findsOneWidget);
    expect(find.text('PAUSADO'), findsNothing);
    await tester.tap(find.byTooltip('Pause'));
    await tester.tap(find.byTooltip('Mute'));
    await tester.pump();
    expect(controller.value.playing, false);
    expect(controller.value.volume, 0);
    await tester.tap(find.byTooltip('Playback speed'));
    await tester.pump();
    expect(find.text('2x'), findsOneWidget);
    expect(controller.value.speed, 2);
    expect(controller.speeds, [2]);
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
    controller.value = LumioPlayerState(
      live: true,
      error: LumioPlayerError(code: 'test', message: 'Failure'),
    );
    await tester.pumpWidget(host(controller, width: 180));
    expect(tester.takeException(), isNull);
    expect(find.byKey(const ValueKey('lumio-progress')), findsNothing);
    expect(find.text('AO VIVO'), findsOneWidget);
    expect(find.textContaining('LIVE'), findsNothing);
    await tester.tap(find.byTooltip('Retry'));
    await tester.pump();
    expect(controller.value.error, isNull);
    await close(tester, controller);
  });

  testWidgets('failed asynchronous commands expose safe feedback', (
    tester,
  ) async {
    final controller = TestController()..fail = true;
    controller.value = LumioPlayerState(initialized: true);
    await tester.pumpWidget(host(controller));
    await tester.tap(find.byTooltip('Play'));
    await tester.pump();
    expect(find.textContaining('Player command failed'), findsOneWidget);
    expect(find.textContaining('secret URL'), findsNothing);
    expect(tester.takeException(), isNull);
    await close(tester, controller);
  });
}
