import 'dart:io';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:lumio_player/lumio_player.dart';

void main() {
  IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  testWidgets('idle player mounts with accessible controls', (tester) async {
    final controller = LumioPlayerController();
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: controller)),
      ),
    );
    expect(find.byTooltip('Play'), findsOneWidget);
    expect(find.byTooltip('Playback engine'), findsOneWidget);
    expect(tester.takeException(), isNull);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native asset video, local file and audio-only asset', (
    tester,
  ) async {
    Future<void> drive(Future<void> operation) async {
      var complete = false;
      Object? failure;
      final handled = operation.then<void>(
        (_) {
          complete = true;
        },
        onError: (Object error) {
          failure = error;
          complete = true;
        },
      );
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (!complete && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(complete, true);
      expect(failure, isNull);
      await handled;
    }

    final video = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: false,
      ),
    );
    addTearDown(video.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: video)),
      ),
    );
    await drive(video.open(LumioSource.asset('assets/sample.mp4')));
    expect(video.value.initialized, true);
    expect(video.value.size.width, greaterThan(0));
    var diagnostics = await video.diagnostics();
    expect((diagnostics['playback'] as Map)['width'], greaterThan(0));
    if (Platform.isIOS) {
      final deadline = DateTime.now().add(const Duration(seconds: 10));
      while (((diagnostics['native'] as Map)['media'] as Map)['videoCodec'] ==
              null &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 200));
        diagnostics = await video.diagnostics();
      }
      expect(
        ((diagnostics['native'] as Map)['media'] as Map)['videoCodec'],
        'avc1',
      );
    }
    final bytes = await rootBundle.load('assets/sample.mp4');
    final directory = await Directory.systemTemp.createTemp('lumio_test_');
    addTearDown(() => directory.delete(recursive: true));
    final file = File('${directory.path}/sample.mp4');
    await file.writeAsBytes(
      bytes.buffer.asUint8List(bytes.offsetInBytes, bytes.lengthInBytes),
    );
    await drive(video.open(LumioSource.file(file.path)));
    expect(video.value.initialized, true);
    await tester.pumpWidget(const SizedBox.shrink());
    await video.dispose();
    final audio = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        mode: LumioPlaybackMode.audio,
        autoPlay: false,
      ),
    );
    addTearDown(audio.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: audio)),
      ),
    );
    await drive(audio.open(LumioSource.asset('assets/sample.wav')));
    expect(audio.value.initialized, true);
    expect(audio.value.duration, greaterThan(Duration.zero));
    await drive(audio.play());
    await tester.pump(const Duration(milliseconds: 500));
    await drive(audio.pause());
    expect(audio.value.position, greaterThan(Duration.zero));
    await tester.pumpWidget(const SizedBox.shrink());
  });

  testWidgets('native playlist auto advances, retains texture and navigates', (
    tester,
  ) async {
    final controller = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: false,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: controller)),
      ),
    );
    Future<void> drive(Future<void> operation) async {
      var done = false;
      Object? error;
      final handled = operation.then<void>(
        (_) => done = true,
        onError: (Object failure) {
          error = failure;
          done = true;
        },
      );
      final deadline = DateTime.now().add(const Duration(seconds: 30));
      while (!done && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(done, true, reason: 'Playlist command timed out');
      expect(error, isNull);
      await handled;
    }

    await drive(
      controller.openPlaylist(
        LumioPlaylist([
          LumioPlaylistItem(
            source: LumioSource.asset('assets/sample.mp4'),
            title: 'First',
          ),
          LumioPlaylistItem(
            source: LumioSource.asset('assets/sample.mp4'),
            title: 'Second',
          ),
        ]),
      ),
    );
    final texture = controller.textureId;
    expect(controller.value.playlistLength, 2);
    expect(controller.title, 'First');
    expect(find.byTooltip('Next item'), findsOneWidget);
    await drive(controller.setSpeed(4));
    await drive(controller.setSpeed(1));
    await drive(controller.play());
    final deadline = DateTime.now().add(const Duration(seconds: 10));
    while (controller.playlistIndex == 0 && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(
      controller.playlistIndex,
      1,
      reason: 'Native queue did not auto advance',
    );
    expect(controller.title, 'Second');
    expect(controller.textureId, texture);
    await drive(controller.pause());
    await drive(controller.previous());
    expect(controller.playlistIndex, 0);
    expect(controller.textureId, texture);
    expect(controller.value.playing, false);
    await drive(controller.next());
    expect(controller.playlistIndex, 1);
    expect(controller.value.playing, false);
    await tester.pumpWidget(const SizedBox.shrink());
  });

  // Opt in with --dart-define=LUMIO_TEST_URL=https://... on an Android/iOS
  // device. The test makes a request to that host; use non-sensitive test media.
  const url = String.fromEnvironment('LUMIO_TEST_URL');
  testWidgets('native playback commands and engine switching', (tester) async {
    final controller = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: false,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: controller)),
      ),
    );
    Future<void> drive(Future<void> operation) async {
      var complete = false;
      Object? failure;
      final handled = operation.then<void>(
        (_) {
          complete = true;
        },
        onError: (Object error) {
          failure = error;
          complete = true;
        },
      );
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while (!complete && DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(complete, true, reason: 'Platform operation timed out');
      expect(failure, isNull);
      await handled;
    }

    await drive(controller.open(LumioSource.network(Uri.parse(url))));
    expect(controller.textureId, isNotNull);
    expect(controller.value.initialized, true);
    await drive(controller.setVolume(0.4));
    await drive(controller.setLooping(true));
    await drive(controller.seekTo(const Duration(seconds: 1)));
    await drive(controller.play());
    await tester.pump(const Duration(seconds: 1));
    await drive(controller.pause());
    final position = controller.value.position;
    expect(position, greaterThanOrEqualTo(const Duration(seconds: 1)));
    await drive(controller.setVideoFit(BoxFit.cover));
    await drive(controller.setEngine(LumioPlaybackEngine.webview));
    expect(controller.webViewController, isNotNull);
    final cover = await controller.webViewController!
        .runJavaScriptReturningResult(
          "document.getElementById('media').style.objectFit",
        );
    expect(cover.toString(), contains('cover'));
    await drive(controller.setVideoFit(BoxFit.fill));
    final fill = await controller.webViewController!
        .runJavaScriptReturningResult(
          "document.getElementById('media').style.objectFit",
        );
    expect(fill.toString(), contains('fill'));
    expect(controller.value.initialized, true);
    if (controller.capabilities.volumeControl) {
      expect(controller.value.volume, closeTo(0.4, 0.01));
    }
    await drive(controller.setVolume(0));
    await tester.pump(const Duration(milliseconds: 200));
    expect(controller.value.volume, 0);
    await drive(controller.setVolume(1));
    await drive(controller.setEngine(LumioPlaybackEngine.native));
    expect(controller.textureId, isNotNull);
    expect(controller.webViewController, isNull);
    expect(controller.value.initialized, true);
    expect(controller.value.volume, closeTo(1, 0.01));
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: url.isEmpty);

  testWidgets(
    'WebView playlist advances and native reopening retains index',
    (tester) async {
      final controller = LumioPlayerController(
        configuration: const LumioPlayerConfiguration(
          engine: LumioPlaybackEngine.webview,
          autoPlay: false,
        ),
      );
      addTearDown(controller.dispose);
      await tester.pumpWidget(
        MaterialApp(
          home: Scaffold(body: LumioPlayerView(controller: controller)),
        ),
      );
      Future<void> drive(Future<void> operation) async {
        var complete = false;
        Object? failure;
        final handled = operation.then<void>(
          (_) => complete = true,
          onError: (Object error) {
            failure = error;
            complete = true;
          },
        );
        final deadline = DateTime.now().add(const Duration(seconds: 35));
        while (!complete && DateTime.now().isBefore(deadline)) {
          await tester.pump(const Duration(milliseconds: 100));
        }
        expect(complete, true);
        expect(failure, isNull);
        await handled;
      }

      await drive(
        controller.openPlaylist(
          LumioPlaylist([
            LumioPlaylistItem(
              source: LumioSource.network(Uri.parse(url)),
              title: 'Web first',
            ),
            LumioPlaylistItem(
              source: LumioSource.network(Uri.parse(url)),
              title: 'Web second',
            ),
          ]),
        ),
      );
      await drive(controller.play());
      await drive(
        controller.seekTo(
          controller.value.duration - const Duration(milliseconds: 200),
        ),
      );
      final deadline = DateTime.now().add(const Duration(seconds: 35));
      while ((controller.playlistIndex == 0 ||
              !controller.value.initialized ||
              controller.value.transitioning) &&
          DateTime.now().isBefore(deadline)) {
        await tester.pump(const Duration(milliseconds: 100));
      }
      expect(controller.playlistIndex, 1);
      expect(controller.value.initialized, true);
      expect(controller.title, 'Web second');
      await drive(controller.pause());
      await drive(controller.setEngine(LumioPlaybackEngine.native));
      expect(controller.playlistIndex, 1);
      expect(controller.value.playlistLength, 2);
      expect(controller.textureId, isNotNull);
      await tester.pumpWidget(const SizedBox.shrink());
    },
    skip: url.isEmpty,
  );

  testWidgets('WebView is mounted before open completes', (tester) async {
    final controller = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.webview,
        autoPlay: false,
      ),
    );
    addTearDown(controller.dispose);
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(body: LumioPlayerView(controller: controller)),
      ),
    );
    var complete = false;
    Object? failure;
    final opening = controller
        .open(LumioSource.network(Uri.parse(url)))
        .then<void>(
          (_) {
            complete = true;
          },
          onError: (Object error) {
            failure = error;
            complete = true;
          },
        );
    final deadline = DateTime.now().add(const Duration(seconds: 35));
    while (!complete && DateTime.now().isBefore(deadline)) {
      await tester.pump(const Duration(milliseconds: 100));
    }
    expect(complete, true, reason: 'WebView initialization timed out');
    expect(failure, isNull);
    expect(controller.webViewController, isNotNull);
    expect(controller.value.initialized, true);
    await opening;
    await tester.pumpWidget(const SizedBox.shrink());
  }, skip: url.isEmpty);
}
