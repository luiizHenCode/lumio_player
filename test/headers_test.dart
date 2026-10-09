import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'playlist_test.dart' show NativePlaylistFake, flushNativeEvents;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativePlaylistFake native;
  late List<LumioPlayerController> players;

  LumioPlayerController player({
    Map<String, String> defaults = const {},
    LumioLogger? logger,
  }) {
    final controller = LumioPlayerController(
      httpHeaders: defaults,
      logger: logger,
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        autoPlay: false,
        allowAutomaticFallback: false,
        initializationTimeout: Duration(seconds: 1),
      ),
    );
    players.add(controller);
    return controller;
  }

  setUp(() {
    native = NativePlaylistFake()..install();
    players = [];
  });
  tearDown(() async {
    for (final controller in players) {
      await controller.dispose();
    }
    native.uninstall();
  });

  test('default headers are copied and immutable before opening', () {
    final defaults = {'Authorization': 'default-token'};
    final controller = player(defaults: defaults);
    defaults['Authorization'] = 'mutated-token';
    defaults['Extra'] = 'mutated';
    expect(controller.httpHeaders, {'Authorization': 'default-token'});
    expect(() => controller.httpHeaders.clear(), throwsUnsupportedError);
    expect(native.calls, isEmpty);
  });

  test(
    'case-insensitive merge precedence is defaults < source < per-open',
    () async {
      final defaults = {
        'Authorization': 'default-token',
        'X-Shared': 'default-shared',
        'X-Default': 'default-only',
      };
      final sourceHeaders = {
        'authorization': 'source-token',
        'x-shared': 'source-shared',
        'X-Source': 'source-only',
      };
      final overrides = {
        'AUTHORIZATION': 'open-token',
        'x-SHARED': 'open-shared',
        'X-Open': 'open-only',
      };
      final source = LumioSource.network(
        Uri.parse('https://example.com/stream.m3u8'),
        headers: sourceHeaders,
        format: LumioMediaFormat.hls,
      );
      final controller = player(defaults: defaults);
      await controller.open(source, headers: overrides, title: 'Stream');
      final expected = {
        'X-Default': 'default-only',
        'X-Source': 'source-only',
        'AUTHORIZATION': 'open-token',
        'x-SHARED': 'open-shared',
        'X-Open': 'open-only',
      };
      expect(controller.source!.headers, expected);
      expect(controller.source!.uri, source.uri);
      expect(controller.source!.format, LumioMediaFormat.hls);
      expect(controller.title, 'Stream');
      final sent =
          (native.named('open').single.arguments as Map)['source'] as Map;
      expect(sent, controller.source!.toMap());
      expect(sent['headers'], expected);
      expect(source.headers, sourceHeaders);
      expect(controller.httpHeaders, defaults);
      overrides['AUTHORIZATION'] = 'later-mutation';
      sourceHeaders['authorization'] = 'later-source-mutation';
      expect(controller.source!.headers, expected);
      expect(
        () => controller.source!.headers['New'] = 'value',
        throwsUnsupportedError,
      );
      expect(
        controller.source!.headers.keys.map((k) => k.toLowerCase()).toSet(),
        hasLength(expected.length),
      );
    },
  );

  test(
    'openUrl forwards URL, title, format and merged headers without leaking prior overrides',
    () async {
      final controller = player(
        defaults: {
          'Authorization': 'default-token',
          'User-Agent': 'test-agent',
        },
      );
      await controller.openUrl(
        'https://example.com/live.m3u8',
        title: 'Live feed',
        format: LumioMediaFormat.hls,
        headers: {'authorization': 'url-token'},
      );
      expect(controller.source!.type, LumioSourceType.network);
      expect(controller.source!.uri, 'https://example.com/live.m3u8');
      expect(controller.source!.format, LumioMediaFormat.hls);
      expect(controller.source!.headers, {
        'User-Agent': 'test-agent',
        'authorization': 'url-token',
      });
      expect(controller.title, 'Live feed');
      expect(
        (native.named('open').last.arguments as Map)['source'],
        controller.source!.toMap(),
      );
      await controller.openUrl('https://example.com/next.mp4');
      expect(controller.source!.headers, {
        'Authorization': 'default-token',
        'User-Agent': 'test-agent',
      });
      expect(controller.source!.format, LumioMediaFormat.auto);
      expect(controller.title, isNull);
      expect(() => controller.openUrl('/relative.mp4'), throwsArgumentError);
    },
  );

  test(
    'file and asset sources never receive default or per-open HTTP headers',
    () async {
      final controller = player(defaults: {'Authorization': 'default-token'});
      for (final source in [
        LumioSource.file('/tmp/video.mp4'),
        LumioSource.asset('assets/video.mp4', package: 'media'),
      ]) {
        await controller.open(source, headers: {'X-Open': 'open-token'});
        expect(controller.source, same(source));
        expect(controller.source!.headers, isEmpty);
        expect(
          (native.named('open').last.arguments as Map)['source'],
          source.toMap(),
        );
      }
    },
  );

  test(
    'playlist defaults and per-open overrides merge independently for every network item',
    () async {
      final controller = player(
        defaults: {
          'Authorization': 'default-token',
          'X-Default': 'shared-default',
        },
      );
      final first = LumioSource.network(
        Uri.parse('https://example.com/first.m3u8'),
        headers: {'authorization': 'first-token', 'X-First': 'first-only'},
        format: LumioMediaFormat.hls,
      );
      final second = LumioSource.network(
        Uri.parse('https://example.com/second.mp4'),
        headers: {'AUTHORIZATION': 'second-token', 'X-Second': 'second-only'},
        format: LumioMediaFormat.progressive,
      );
      final local = LumioSource.file('/tmp/local.mp4');
      final asset = LumioSource.asset('assets/local.mp4');
      final playlist = LumioPlaylist([
        LumioPlaylistItem(source: first, title: 'First'),
        LumioPlaylistItem(source: second, title: 'Second'),
        LumioPlaylistItem(source: local),
        LumioPlaylistItem(source: asset),
      ], loop: true);
      await controller.openPlaylist(playlist, initialIndex: 1);
      expect(controller.playlist!.items[0].source.headers, {
        'X-Default': 'shared-default',
        'authorization': 'first-token',
        'X-First': 'first-only',
      });
      expect(controller.playlist!.items[1].source.headers, {
        'X-Default': 'shared-default',
        'AUTHORIZATION': 'second-token',
        'X-Second': 'second-only',
      });
      final overrides = {
        'aUtHoRiZaTiOn': 'playlist-token',
        'X-Open': 'shared-open',
      };
      await controller.openPlaylist(playlist, headers: overrides);
      final effective = controller.playlist!;
      expect(effective.items[0].source.headers, {
        'X-Default': 'shared-default',
        'X-First': 'first-only',
        'aUtHoRiZaTiOn': 'playlist-token',
        'X-Open': 'shared-open',
      });
      expect(effective.items[1].source.headers, {
        'X-Default': 'shared-default',
        'X-Second': 'second-only',
        'aUtHoRiZaTiOn': 'playlist-token',
        'X-Open': 'shared-open',
      });
      expect(effective.items[2].source, same(local));
      expect(effective.items[3].source, same(asset));
      expect(effective.items[2].source.headers, isEmpty);
      expect(effective.items[3].source.headers, isEmpty);
      expect(effective.items[0].source.format, LumioMediaFormat.hls);
      expect(effective.items[1].source.format, LumioMediaFormat.progressive);
      expect(effective.items.map((i) => i.title), [
        'First',
        'Second',
        null,
        null,
      ]);
      expect(effective.loop, isTrue);
      final sent = native.named('openPlaylist').last.arguments as Map;
      expect(
        sent['sources'],
        effective.items.map((i) => i.source.toMap()).toList(),
      );
      overrides.clear();
      expect(effective.items.first.source.headers['X-Open'], 'shared-open');
      expect(first.headers, {
        'authorization': 'first-token',
        'X-First': 'first-only',
      });
      expect(second.headers, {
        'AUTHORIZATION': 'second-token',
        'X-Second': 'second-only',
      });
      await controller.selectPlaylistItem(1);
      expect(controller.source, same(effective.items[1].source));
      await controller.retry();
      expect(
        (native.named('openPlaylist').last.arguments as Map)['sources'],
        sent['sources'],
      );
    },
  );

  test(
    'all playlist secrets are redacted from errors, logger, stream and nested diagnostics',
    () async {
      final logged = <LumioLogEntry>[];
      final streamed = <LumioLogEntry>[];
      final controller = player(
        defaults: {'X-Default': 'default-secret-marker'},
        logger: logged.add,
      );
      final subscription = controller.logs.listen(streamed.add);
      addTearDown(subscription.cancel);
      final playlist = LumioPlaylist([
        for (var i = 0; i < 3; i++)
          LumioPlaylistItem(
            source: LumioSource.network(
              Uri.parse(
                'https://user-$i:password-$i@example.com/$i?token=url-secret-$i',
              ),
              headers: {'Authorization': 'item-secret-marker-$i'},
            ),
          ),
      ]);
      await controller.openPlaylist(
        playlist,
        initialIndex: 1,
        headers: {'X-Open': 'open-secret-marker'},
      );
      final secrets = [
        'default-secret-marker',
        'open-secret-marker',
        for (var i = 0; i < 3; i++) 'item-secret-marker-$i',
        for (final item in playlist.items) item.source.uri,
      ];
      final unsafe = 'Native failure: ${secrets.join(' ')}';
      native.diagnosticsResult = {
        'access': [
          unsafe,
          {'nested': unsafe, 'count': 7},
        ],
        'safe': 'decoder-ready',
      };
      await native.emit({
        'id': native.id,
        'type': 'error',
        'playlistIndex': 1,
        'code': 'decoder_error',
        'message': unsafe,
        'details': {'nested': unsafe},
      });
      await flushNativeEvents();
      final error = controller.value.error!;
      expect(error.code, 'decoder_error');
      expect(error.message, contains('[redacted]'));
      expect(error.message, contains('[source]'));
      final diagnostics = await controller.diagnostics();
      expect(diagnostics['native'], {
        'access': [
          error.message,
          {'nested': error.message, 'count': 7},
        ],
        'safe': 'decoder-ready',
      });
      final publicOutputs = [
        error.message,
        error.details.toString(),
        error.toString(),
        diagnostics.toString(),
        ...logged.map((entry) => entry.toString()),
        ...streamed.map((entry) => entry.toString()),
        ...playlist.items.map((item) => item.source.toString()),
      ];
      expect(logged.any((e) => e.code == 'decoder_error'), isTrue);
      expect(streamed.any((e) => e.code == 'decoder_error'), isTrue);
      for (final output in publicOutputs) {
        for (final secret in secrets) {
          expect(
            output,
            isNot(contains(secret)),
            reason: 'Secret leaked in $output',
          );
        }
        for (var i = 0; i < 3; i++) {
          expect(output, isNot(contains('password-$i')));
          expect(output, isNot(contains('url-secret-$i')));
        }
      }
      // Wire payloads must retain credentials: redaction is for public diagnostics.
      final sources =
          (native.named('openPlaylist').single.arguments as Map)['sources']
              as List;
      expect((sources[0] as Map)['uri'], playlist.items[0].source.uri);
      expect(
        (sources[2] as Map)['headers']['Authorization'],
        'item-secret-marker-2',
      );
    },
  );
}
