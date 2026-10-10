import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/src/controls_configuration.dart';
import 'package:lumio_player/src/models.dart';

import 'gestures_test.dart' show surfaceKey;
import 'player_view_test.dart' show TestController, close, host;

const _seekKey = ValueKey('lumio-seek-feedback');
const _holdKey = ValueKey('lumio-hold-speed-feedback');
const _holdLabelKey = ValueKey('lumio-hold-speed-label');
const _ready = LumioPlayerState(
  initialized: true,
  duration: Duration(minutes: 1),
  position: Duration(seconds: 30),
);

Offset _point(WidgetTester tester, {bool forward = true}) {
  final rect = tester.getRect(find.byKey(surfaceKey));
  return Offset(forward ? rect.right - 25 : rect.left + 25, rect.top + 25);
}

Future<void> _doubleTap(WidgetTester tester, {bool forward = true}) async {
  // Separate successive confirmed pairs, without consuming the badge timeout.
  await tester.pump(const Duration(milliseconds: 50));
  final point = _point(tester, forward: forward);
  await tester.tapAt(point);
  await tester.pump(const Duration(milliseconds: 80));
  await tester.tapAt(point);
  await tester.pump();
}

void _expectSeek(String label, {bool forward = true}) {
  final badge = find.byKey(_seekKey);
  expect(badge, findsOneWidget);
  expect(
    find.descendant(of: badge, matching: find.text(label)),
    findsOneWidget,
  );
  expect(
    find.descendant(
      of: badge,
      matching: find.byIcon(
        forward ? Icons.fast_forward_rounded : Icons.fast_rewind_rounded,
      ),
    ),
    findsOneWidget,
  );
  expect(
    find.descendant(
      of: badge,
      matching: find.byIcon(
        forward ? Icons.fast_rewind_rounded : Icons.fast_forward_rounded,
      ),
    ),
    findsNothing,
  );
}

void main() {
  for (final forward in [true, false]) {
    testWidgets(
      'seek feedback accumulates ${forward ? 'forward' : 'backward'}',
      (tester) async {
        final controller = TestController()..value = _ready;
        await tester.pumpWidget(host(controller));
        expect(find.byKey(_seekKey), findsNothing);
        await _doubleTap(tester, forward: forward);
        _expectSeek('${forward ? '+' : '-'}10s', forward: forward);
        expect(controller.sought, Duration(seconds: forward ? 40 : 20));
        controller.value = controller.value.copyWith(
          position: controller.sought,
        );
        await tester.pump();
        await _doubleTap(tester, forward: forward);
        _expectSeek('${forward ? '+' : '-'}20s', forward: forward);
        expect(controller.sought, Duration(seconds: forward ? 50 : 10));
        await close(tester, controller);
      },
    );

    testWidgets(
      'feedback reports requested increments at ${forward ? 'end' : 'start'}',
      (tester) async {
        final controller = TestController()
          ..value = _ready.copyWith(
            position: Duration(seconds: forward ? 55 : 5),
          );
        await tester.pumpWidget(host(controller));
        for (final total in [10, 20]) {
          await _doubleTap(tester, forward: forward);
          _expectSeek('${forward ? '+' : '-'}${total}s', forward: forward);
          expect(controller.sought, forward ? _ready.duration : Duration.zero);
          controller.value = controller.value.copyWith(
            position: controller.sought,
          );
          await tester.pump();
        }
        await close(tester, controller);
      },
    );
  }

  testWidgets('changing direction starts a new feedback sequence', (
    tester,
  ) async {
    final controller = TestController()..value = _ready;
    await tester.pumpWidget(host(controller));
    await _doubleTap(tester);
    await _doubleTap(tester);
    _expectSeek('+20s');
    await _doubleTap(tester, forward: false);
    _expectSeek('-10s', forward: false);
    await _doubleTap(tester, forward: false);
    _expectSeek('-20s', forward: false);
    await _doubleTap(tester);
    _expectSeek('+10s');
    await close(tester, controller);
  });

  testWidgets(
    'timeout is 900 ms after the latest double tap and resets total',
    (tester) async {
      final controller = TestController()..value = _ready;
      await tester.pumpWidget(host(controller));
      await _doubleTap(tester);
      await tester.pump(const Duration(milliseconds: 500));
      await _doubleTap(tester);
      _expectSeek('+20s');
      await tester.pump(const Duration(milliseconds: 899));
      _expectSeek('+20s');
      await tester.pump(const Duration(milliseconds: 1));
      expect(find.byKey(_seekKey), findsNothing);
      await _doubleTap(tester);
      _expectSeek('+10s');
      await close(tester, controller);
    },
  );

  testWidgets('timeout waits for the last held pointer to be released', (
    tester,
  ) async {
    final controller = TestController()..value = _ready;
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(holdToSpeed: false),
      ),
    );
    await _doubleTap(tester);
    await tester.pump(const Duration(milliseconds: 100));
    final first = await tester.startGesture(_point(tester), pointer: 1);
    final second = await tester.startGesture(
      _point(tester, forward: false),
      pointer: 2,
    );
    await tester.pump(const Duration(seconds: 2));
    _expectSeek('+10s');
    await first.up();
    await tester.pump(const Duration(seconds: 1));
    _expectSeek('+10s');
    await second.up();
    await tester.pump();
    await tester.pump(const Duration(milliseconds: 899));
    _expectSeek('+10s');
    await tester.pump(const Duration(milliseconds: 1));
    expect(find.byKey(_seekKey), findsNothing);
    await close(tester, controller);
  });

  testWidgets('custom seek interval determines cumulative feedback', (
    tester,
  ) async {
    final controller = TestController()..value = _ready;
    await tester.pumpWidget(
      host(
        controller,
        configuration: const LumioControlsConfiguration(
          seekInterval: Duration(seconds: 3),
        ),
      ),
    );
    await _doubleTap(tester);
    _expectSeek('+3s');
    expect(controller.sought, const Duration(seconds: 33));
    await _doubleTap(tester);
    _expectSeek('+6s');
    await _doubleTap(tester, forward: false);
    _expectSeek('-3s', forward: false);
    expect(controller.sought, const Duration(seconds: 27));
    await _doubleTap(tester, forward: false);
    _expectSeek('-6s', forward: false);
    await close(tester, controller);
  });

  testWidgets(
    'second tap down does not seek; canceled double tap has no badge',
    (tester) async {
      final controller = TestController()..value = _ready;
      await tester.pumpWidget(host(controller));
      final point = _point(tester);
      await tester.tapAt(point);
      await tester.pump(const Duration(milliseconds: 80));
      final second = await tester.startGesture(point);
      await tester.pump();
      expect(controller.sought, isNull);
      expect(find.byKey(_seekKey), findsNothing);
      await second.cancel();
      await tester.pump(const Duration(milliseconds: 350));
      expect(controller.sought, isNull);
      expect(find.byKey(_seekKey), findsNothing);
      await _doubleTap(tester);
      _expectSeek('+10s');
      expect(controller.sought, const Duration(seconds: 40));
      await close(tester, controller);
    },
  );

  for (final scenario in [
    'controls off',
    'configuration off',
    'gesture off',
    'unseekable',
    'live state',
    'live mode',
    'live layout',
    'not ready',
    'error',
  ]) {
    testWidgets('$scenario never seeks or shows feedback', (tester) async {
      final controller =
          TestController(
              configuration: LumioPlayerConfiguration(
                mode: scenario == 'live mode'
                    ? LumioPlaybackMode.live
                    : LumioPlaybackMode.video,
              ),
            )
            ..value = _ready.copyWith(
              initialized: scenario != 'not ready',
              duration: scenario == 'unseekable'
                  ? Duration.zero
                  : _ready.duration,
              live: scenario == 'live state',
              error: scenario == 'error'
                  ? const LumioPlayerError(code: 'test', message: 'Failure')
                  : null,
            );
      await tester.pumpWidget(
        host(
          controller,
          controls: scenario != 'controls off',
          configuration: LumioControlsConfiguration(
            enabled: scenario != 'configuration off',
            doubleTapSeek: scenario != 'gesture off',
            layout: scenario == 'live layout'
                ? LumioControlsLayout.live
                : LumioControlsLayout.automatic,
          ),
        ),
      );
      await _doubleTap(tester);
      expect(controller.sought, isNull);
      expect(find.byKey(_seekKey), findsNothing);
      await close(tester, controller);
    });
  }

  for (final change in [
    'source',
    'engine',
    'not ready',
    'error',
    'gesture off',
  ]) {
    testWidgets('$change clears feedback and resets the sequence', (
      tester,
    ) async {
      final controller = TestController()
        ..testSource = LumioSource.network(
          Uri.parse('https://example.com/a.mp4'),
        )
        ..value = _ready;
      await tester.pumpWidget(host(controller));
      await _doubleTap(tester);
      await _doubleTap(tester);
      _expectSeek('+20s');
      switch (change) {
        case 'source':
          controller.testSource = LumioSource.network(
            Uri.parse('https://example.com/b.mp4'),
          );
          controller.notifyListeners();
        case 'engine':
          controller.value = controller.value.copyWith(
            engine: LumioPlaybackEngine.webview,
          );
        case 'not ready':
          controller.value = controller.value.copyWith(initialized: false);
        case 'error':
          controller.value = controller.value.copyWith(
            error: const LumioPlayerError(code: 'test', message: 'Failure'),
          );
        case 'gesture off':
          await tester.pumpWidget(
            host(
              controller,
              configuration: const LumioControlsConfiguration(
                doubleTapSeek: false,
              ),
            ),
          );
      }
      await tester.pump();
      expect(find.byKey(_seekKey), findsNothing);
      controller.value = controller.value.copyWith(
        initialized: true,
        clearError: true,
      );
      await tester.pumpWidget(host(controller));
      await _doubleTap(tester);
      _expectSeek('+10s');
      await close(tester, controller);
    });
  }

  testWidgets('controller replacement clears feedback and resets sequence', (
    tester,
  ) async {
    final first = TestController()..value = _ready;
    final second = TestController()..value = _ready;
    await tester.pumpWidget(host(first));
    await _doubleTap(tester);
    await _doubleTap(tester);
    _expectSeek('+20s');
    await tester.pumpWidget(host(second));
    expect(find.byKey(_seekKey), findsNothing);
    await _doubleTap(tester);
    _expectSeek('+10s');
    expect(second.sought, const Duration(seconds: 40));
    await close(tester, first);
    await close(tester, second);
  });

  for (final speed in [1.0, 2.0]) {
    testWidgets('hold feedback at ${speed}x is a padded rounded pill', (
      tester,
    ) async {
      final controller = TestController()
        ..value = _ready.copyWith(speed: speed);
      await tester.pumpWidget(host(controller));
      final gesture = await tester.startGesture(_point(tester));
      await tester.pump(kLongPressTimeout + const Duration(milliseconds: 20));
      final pill = find.byKey(_holdKey);
      final label = find.byKey(_holdLabelKey);
      expect(pill, findsOneWidget);
      expect(find.descendant(of: pill, matching: label), findsOneWidget);
      final text = tester.widget<Text>(label);
      expect(text.data, speed == 1 ? '2x' : '1x');
      expect(text.style?.backgroundColor, isNull);
      final decorations = tester.widgetList<DecoratedBox>(
        find.descendant(
          of: pill,
          matching: find.byType(DecoratedBox),
          matchRoot: true,
        ),
      );
      expect(
        decorations.any((widget) {
          final decoration = widget.decoration;
          return (decoration is BoxDecoration &&
                  decoration.color != null &&
                  decoration.borderRadius != null &&
                  decoration.borderRadius != BorderRadius.zero) ||
              (decoration is ShapeDecoration &&
                  decoration.color != null &&
                  (decoration.shape is StadiumBorder ||
                      decoration.shape is RoundedRectangleBorder));
        }),
        isTrue,
        reason:
            'The badge background belongs to a rounded decoration, not Text.',
      );
      expect(
        tester.getSize(pill).width,
        greaterThan(tester.getSize(label).width),
      );
      expect(
        tester.getSize(pill).height,
        greaterThan(tester.getSize(label).height),
      );
      await gesture.up();
      await tester.pump();
      expect(pill, findsNothing);
      await close(tester, controller);
    });
  }

  testWidgets('disposing a visible seek badge cancels its timeout', (
    tester,
  ) async {
    final controller = TestController()..value = _ready;
    await tester.pumpWidget(host(controller));
    await _doubleTap(tester);
    _expectSeek('+10s');
    await close(tester, controller);
    await tester.pump(const Duration(seconds: 1));
    expect(tester.takeException(), isNull);
  });
}
