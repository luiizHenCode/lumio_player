import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;

void main() {
  for (final platform in [TargetPlatform.android, TargetPlatform.iOS]) {
    testWidgets(
      '$platform chooses, remounts and transfers one native surface to fullscreen',
      (tester) async {
        debugDefaultTargetPlatformOverride = platform;
        final native = NativeMock()..install();
        final surfaceCalls = <MethodCall>[];
        final messenger =
            TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
        messenger.setMockMethodCallHandler(SystemChannels.platform_views, (
          call,
        ) async {
          surfaceCalls.add(call);
          if (call.method == 'create') return 100;
          if (call.method == 'resize') {
            final args = call.arguments as Map;
            return {'width': args['width'], 'height': args['height']};
          }
          return null;
        });
        native.intercept = (call) async {
          if (call.method == 'create') return {'id': native.nextId++};
          return await native.respond(call);
        };
        final controller = LumioPlayerController(
          configuration: const LumioPlayerConfiguration(
            engine: LumioPlaybackEngine.native,
            nativeViewType: LumioNativeViewType.platformView,
            autoPlay: false,
          ),
        );
        try {
          final opening = controller.openUrl('https://example.com/video.mp4');
          await tester.pump();
          await opening;
          await tester.pumpWidget(
            MaterialApp(
              home: Scaffold(
                body: SizedBox(
                  height: 300,
                  child: LumioPlayerView(
                    controller: controller,
                    layout: LumioVideoLayout.expand,
                  ),
                ),
              ),
            ),
          );
          await tester.pump();
          final type = platform == TargetPlatform.android
              ? AndroidView
              : UiKitView;
          expect(find.byType(type), findsOneWidget);
          expect(find.byType(Texture), findsNothing);
          final first = tester.widget(find.byType(type));
          if (first is AndroidView) {
            expect(first.viewType, 'lumio_player/native_view');
            expect(first.creationParams, {'id': 1});
            expect(first.creationParamsCodec, isA<StandardMessageCodec>());
          } else if (first is UiKitView) {
            expect(first.viewType, 'lumio_player/native_view');
            expect(first.creationParams, {'id': 1});
            expect(first.creationParamsCodec, isA<StandardMessageCodec>());
          }
          final reopening = controller.openUrl('https://example.com/next.mp4');
          await tester.pump();
          await reopening;
          await tester.pump();
          expect(
            find.byKey(const ValueKey('lumio-native-view-1')),
            findsNothing,
          );
          expect(
            find.byKey(const ValueKey('lumio-native-view-2')),
            findsOneWidget,
          );

          await tester.tap(find.byTooltip('Fullscreen'));
          await tester.pump();
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          expect(find.byType(type, skipOffstage: false), findsOneWidget);
          await tester.tap(find.byTooltip('Exit fullscreen'));
          await tester.pump();
          await tester.pump(const Duration(milliseconds: 400));
          await tester.pump();
          expect(find.byType(type, skipOffstage: false), findsOneWidget);
          expect(
            surfaceCalls.where((call) => call.method == 'dispose'),
            isNotEmpty,
          );
          expect(tester.takeException(), isNull);
        } finally {
          await tester.pumpWidget(const SizedBox.shrink());
          final closing = controller.dispose();
          await tester.pump();
          await closing;
          native.uninstall();
          messenger.setMockMethodCallHandler(
            SystemChannels.platform_views,
            null,
          );
          debugDefaultTargetPlatformOverride = null;
        }
      },
    );
  }
}
