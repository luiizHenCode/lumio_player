import 'dart:async';
import 'dart:convert';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:lumio_player/lumio_player.dart';

import 'controller_test.dart' show NativeMock;

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  late NativeMock native;
  late LumioPlayerController player;
  var diagnostics = <String, Object?>{};
  final source = LumioSource.network(
    Uri.parse(
      'https://known-user:known-pass@example.com/private?token=known-token',
    ),
    headers: {'Authorization': 'Bearer known-header'},
  );

  Future<void> emit({String code = 'network', Object? details}) async {
    await native.emit({
      'id': native.nextId - 1,
      'type': 'error',
      'code': code,
      'message':
          'unknown-password /Users/private/customer '
          'content://secret file:///private/secret Bearer arbitrary-token',
      'details': details,
      'recoverable': true,
    });
    await Future<void>.delayed(Duration.zero);
  }

  setUp(() {
    diagnostics = {};
    native = NativeMock()..install();
    native.intercept = (call) async {
      if (call.method == 'diagnostics') return diagnostics;
      return native.respond(call);
    };
    player = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        engine: LumioPlaybackEngine.native,
        allowAutomaticFallback: false,
      ),
    );
  });
  tearDown(() async {
    await player.dispose();
    native.uninstall();
  });

  for (final code in const [
    // Public codes from web_engine.dart and player.js, not HLS.js internals.
    'media_failed',
    'webview_load_failed',
    'webview_setup_failed',
    'unsupported_source',
    'unsupported_headers',
    'unsupported_format',
    'invalid_argument',
    'initialization_timeout',
    'unsupported_command',
    'not_ready',
    'command_timeout',
    'playback_blocked',
    'media_error',
    'unsupported_hls',
    'hls_network_error',
    'hls_media_error',
    'open_cancelled',
    'command_failed',
    'unsupported_live_seek',
    // Fixed native operation codes and AVFoundation failure phase.
    'engine_detached',
    'preview_seek_pending',
    'preview_seek_failed',
    'cancelled',
    'playback_failed',
    'not_initialized',
    'disposed',
    'seek_cancelled',
    'invalid_player',
    'asset_not_found',
    'file_not_found',
  ]) {
    test('report preserves exact public failure code: $code', () async {
      await player.open(source);
      diagnostics = {
        'lastError': {'code': code, 'message': 'private-native-message'},
      };
      await emit(code: code, details: {'code': code});
      final report = (await player.failureReport())!;
      expect(report.code, code);
      expect(report.metadata['details'], {'code': code});
      expect(report.metadata['native'], {
        'lastError': {'code': code},
      });
      expect(report.formattedText, contains('Code: $code\n'));
      expect(report.formattedText, isNot(contains('private-native-message')));
      expect(report.formattedText, isNot(contains('unknown-password')));
    });
  }

  test(
    'public code allowlist rejects arbitrary strings and near matches',
    () async {
      await player.open(source);
      for (final code in const [
        'arbitrary-private-token',
        'media_error_token',
        'hls_network_error https://user:password@example.com?token=secret',
        'MEDIA_ERROR',
        'media_error\n',
        ' media_error',
        'invalid_fit',
        'fragLoadError',
        'bridge_dispatch_failed',
      ]) {
        diagnostics = {
          'lastError': {'code': code},
        };
        await emit(code: code, details: {'code': code});
        final report = (await player.failureReport())!;
        expect(report.code, 'unknown_error');
        expect(report.metadata['details'], {'code': 'unknown_error'});
        expect(report.metadata['native'], {
          'lastError': {'code': 'unknown_error'},
        });
        expect(report.formattedText, isNot(contains(code)));
      }
    },
  );

  test(
    'device diagnostics expose only platform SDK and restricted OS version',
    () async {
      await player.open(source);
      diagnostics = {
        'sdkInt': 36,
        'androidVersion': '16.0.1',
        'model': 'Customer Phone',
        'manufacturer': 'customer-secret',
        'device': {
          'platform': 'iOS',
          'systemVersion': '26.0.1',
          'name': 'Customer Phone',
          'model': 'customer-secret',
          'identifierForVendor': 'private-identifier',
        },
      };
      await emit();
      final report = (await player.failureReport())!;
      expect(report.metadata['native'], {
        'sdkInt': 36,
        'androidVersion': '16.0.1',
        'device': {'platform': 'iOS', 'systemVersion': '26.0.1'},
      });
      expect(report.metadata['platform'], isA<String>());
      for (final secret in [
        'Customer Phone',
        'customer-secret',
        'private-identifier',
      ]) {
        expect(report.formattedText, isNot(contains(secret)));
      }
      for (final version in [
        '16 token=secret',
        '26.0\n',
        '/16.0',
        '16.0-beta',
        'Bearer 16',
        'https://16.0',
        '1..2',
        '1234.1',
        '1.2.3.4.5',
        '',
      ]) {
        diagnostics = {
          'sdkInt': '36 secret',
          'androidVersion': version,
          'device': {'platform': 'Customer Phone', 'systemVersion': version},
        };
        await emit();
        expect((await player.failureReport())!.metadata['native'], {
          'device': {},
        });
      }
      diagnostics = {
        'sdkInt': -1,
        'androidVersion': 16,
        'device': {'systemVersion': 26},
      };
      await emit();
      expect((await player.failureReport())!.metadata['native'], {
        'androidVersion': 16,
        'device': {'systemVersion': 26},
      });
    },
  );

  test(
    'Android 404 and iOS numeric chains survive without arbitrary cause text',
    () async {
      await player.open(source);
      await emit(
        code: 'ERROR_CODE_IO_BAD_HTTP_STATUS',
        details: {
          'errorCode': 2004,
          'httpStatus': 404,
          'causeMessage': 'Response code: 404 user=secret',
          'cause': 'private-class-name',
        },
      );
      final android = (await player.failureReport())!;
      expect(android.code, 'ERROR_CODE_IO_BAD_HTTP_STATUS');
      expect(android.metadata['details'], {
        'errorCode': 2004,
        'httpStatus': 404,
      });
      expect(android.formattedText, contains('404'));
      expect(android.formattedText, isNot(contains('user=secret')));
      await emit(
        code: 'ios_native_terminal_error',
        details: {
          'nativeCode': -11800,
          'nativeErrorChain': [
            {'domain': 'AVFoundationErrorDomain', 'code': -11800},
            {
              'domain': 'unknown-private-domain',
              'code': -1005,
              'message': 'secret',
            },
          ],
        },
      );
      final ios = (await player.failureReport())!;
      expect((ios.metadata['details'] as Map)['nativeErrorChain'], [
        {'domain': 'AVFoundationErrorDomain', 'code': -11800},
        {'code': -1005},
      ]);
      expect(ios.formattedText, isNot(contains('unknown-private-domain')));
      expect(ios.formattedText, isNot(contains('secret')));
      expect(android.metadata['details'], {
        'errorCode': 2004,
        'httpStatus': 404,
      });
    },
  );

  for (final eventFailure in [false, true]) {
    test(
      'initial failure before dispose freezes failed engine: event=$eventFailure',
      () async {
        native.intercept = (call) async {
          if (call.method == 'open') {
            if (eventFailure) {
              await native.emit({
                'id': (call.arguments as Map)['id'],
                'type': 'error',
                'code': 'ERROR_CODE_IO_BAD_HTTP_STATUS',
                'message': 'private message',
                'details': {'httpStatus': 404},
              });
              return null;
            }
            throw PlatformException(
              code: 'ERROR_CODE_IO_BAD_HTTP_STATUS',
              details: {'httpStatus': 404},
            );
          }
          if (call.method == 'diagnostics') {
            return {
              'sdkInt': 36,
              'player': {'httpStatus': 404},
            };
          }
          return native.respond(call);
        };
        await expectLater(
          player.open(source),
          throwsA(isA<LumioPlayerError>()),
        );
        await player.dispose();
        final report = (await player.failureReport())!;
        expect(report.metadata['engine'], 'native');
        expect(report.metadata['details'], {'httpStatus': 404});
        expect(report.metadata['native'], {
          'sdkInt': 36,
          'player': {'httpStatus': 404},
        });
        final captured = native.named('diagnostics').single;
        expect((captured.arguments as Map)['id'], 1);
        expect(
          native.calls.indexOf(captured),
          lessThan(native.calls.indexOf(native.named('dispose').first)),
        );
      },
    );
  }

  test(
    'early WebView failure cannot capture previous native engine diagnostics',
    () async {
      await player.open(source);
      await emit();
      final nativeReport = (await player.failureReport())!;
      await expectLater(
        player.setEngine(LumioPlaybackEngine.webview),
        throwsA(isA<LumioPlayerError>()),
      );
      final webReport = (await player.failureReport())!;
      expect(webReport.code, 'unsupported_web_source');
      expect(webReport.metadata['engine'], 'webview');
      expect(webReport.metadata['native'], isEmpty);
      expect(native.named('diagnostics'), hasLength(1));
      expect(nativeReport.metadata['engine'], 'native');
      expect(nativeReport.code, 'network');
    },
  );

  test(
    'create failure has historical metadata without native diagnostics',
    () async {
      native.intercept = (call) async {
        if (call.method == 'create') {
          throw PlatformException(code: 'open_failed');
        }
        return native.respond(call);
      };
      await expectLater(player.open(source), throwsA(isA<LumioPlayerError>()));
      await player.dispose();
      final report = (await player.failureReport())!;
      expect(report.metadata['engine'], 'native');
      expect(report.code, 'open_failed');
      expect(report.metadata['diagnosticsStatus'], 'unavailable');
      expect(native.named('diagnostics'), isEmpty);
    },
  );

  test('no failure returns null including after disposal', () async {
    expect(await player.failureReport(), isNull);
    await player.dispose();
    expect(await player.failureReport(), isNull);
    expect(native.named('diagnostics'), isEmpty);
  });

  test(
    'report uses strict structured allowlists and immutable metadata',
    () async {
      diagnostics = {
        'backend': 'AVQueuePlayer',
        'player': {
          'videoBitrate': 12345,
          'videoMimeType': 'video/avc',
          'videoDecoderName': 'arbitrary-token',
          'audioMimeType': 'Bearer secret',
          'sourceType':
              'https://unknown:password@other.example/stream?key=secret',
          'frameRate': double.infinity,
          'state': {'positionMs': 250, 'title': 'customer-name'},
        },
        'accessLog': [
          {
            'observedBitrate': 900,
            'uri': source.uri,
            'comment': 'unknown-password',
          },
        ],
        'Authorization': 'Bearer arbitrary-token',
        'unknown-key-secret': {'nativeCode': 123},
      };
      await player.open(source, title: 'customer-name');
      await emit(
        details: {
          'nativeCode': -11800,
          'httpStatus': 503,
          'nativeErrorChain': [
            {
              'domain': 'NSURLErrorDomain',
              'code': -1005,
              'message': 'known-header',
            },
            {'domain': 'customer-name', 'code': -999},
          ],
          'errorLogStatusCodes': [404, 'Bearer arbitrary-token'],
          'nativeErrorPhase': 'customer-name',
          'details': {'httpStatus': '503 password=unknown-password'},
          'headers': source.headers,
          'causeMessage': 'token=unknown-password /private/secret',
          'uri': source.uri,
        },
      );
      final report = (await player.failureReport())!;
      expect(report.code, 'network');
      expect(report.timestamp.isUtc, isTrue);
      expect(report.metadata['diagnosticsStatus'], 'captured');
      final details = report.metadata['details'] as Map;
      expect(details['httpStatus'], 503);
      expect((details['nativeErrorChain'] as List).first, {
        'domain': 'NSURLErrorDomain',
        'code': -1005,
      });
      final serialized =
          '${report.formattedText} ${jsonEncode(report.metadata)}';
      for (final secret in [
        'known-user',
        'known-pass',
        'known-token',
        'known-header',
        'example.com',
        'unknown-password',
        'arbitrary-token',
        'customer-name',
        'other.example',
        'Authorization',
        'unknown-key-secret',
        '/private',
        '/Users',
        'content://',
        'file://',
        'Bearer',
        'Infinity',
      ]) {
        expect(serialized, isNot(contains(secret)), reason: secret);
      }
      expect(() => report.metadata['engine'] = 'x', throwsUnsupportedError);
      expect(() => details['httpStatus'] = 200, throwsUnsupportedError);
      expect(
        () => (details['nativeErrorChain'] as List).add({}),
        throwsUnsupportedError,
      );
      expect(
        () => ((details['nativeErrorChain'] as List).first as Map)['code'] = 0,
        throwsUnsupportedError,
      );
    },
  );

  test(
    'unknown codes and arbitrary details strings are never copied',
    () async {
      await player.open(source);
      await emit(
        code: 'innocent_identifier_customer_token',
        details: 'password=unknown',
      );
      final report = (await player.failureReport())!;
      expect(report.code, 'unknown_error');
      expect(report.metadata['details'], isEmpty);
      expect(report.formattedText, isNot(contains('innocent_identifier')));
      expect(report.formattedText, isNot(contains('password=')));
    },
  );

  test('manual retry preserves timestamp and old engine diagnostics', () async {
    diagnostics = {
      'player': {'videoBitrate': 111},
    };
    await player.open(source);
    await emit();
    // Retry immediately; release must capture the failed engine first.
    await player.retry();
    final report = (await player.failureReport())!;
    expect(player.value.error, isNull);
    expect((report.metadata['native'] as Map)['player'], {'videoBitrate': 111});
    final captured = native.named('diagnostics').single;
    expect((captured.arguments as Map)['id'], 1);
    expect(
      native.calls.indexOf(captured),
      lessThan(native.calls.indexOf(native.named('dispose').first)),
    );
    diagnostics = {
      'player': {'videoBitrate': 222},
    };
    expect((await player.failureReport())!.timestamp, report.timestamp);
    expect(native.named('diagnostics'), hasLength(1));
    await player.dispose();
    expect((await player.failureReport())!.formattedText, report.formattedText);
    expect(native.named('diagnostics'), hasLength(1));
  });

  test('automatic recovery clears state but keeps failure snapshot', () async {
    await player.dispose();
    player = LumioPlayerController(
      configuration: const LumioPlayerConfiguration(
        mode: LumioPlaybackMode.live,
        engine: LumioPlaybackEngine.native,
        allowAutomaticFallback: false,
      ),
      recovery: const LumioRecoveryConfiguration(
        enabled: true,
        initialDelay: Duration(milliseconds: 10),
        maxDelay: Duration(milliseconds: 20),
      ),
    );
    await player.open(source);
    await emit();
    final before = (await player.failureReport())!;
    await Future<void>.delayed(const Duration(milliseconds: 60));
    expect(native.named('open'), hasLength(2));
    expect(player.value.error, isNull);
    final after = (await player.failureReport())!;
    expect(after.timestamp, before.timestamp);
    expect((after.metadata['recovery'] as Map)['attempts'], 0);
  });

  test(
    'open PlatformException captures details before native release',
    () async {
      native.intercept = (call) async {
        if (call.method == 'open') {
          throw PlatformException(
            code: 'open_failed',
            message: 'user=customer password=secret',
            details: {
              'nativeCode': -1005,
              'httpStatus': 503,
              'password': 'secret',
            },
          );
        }
        if (call.method == 'diagnostics') return {'itemStatus': 2};
        return native.respond(call);
      };
      await expectLater(player.open(source), throwsA(isA<LumioPlayerError>()));
      final report = (await player.failureReport())!;
      expect(report.code, 'open_failed');
      expect(report.metadata['details'], {
        'nativeCode': -1005,
        'httpStatus': 503,
      });
      expect(report.metadata['native'], {'itemStatus': 2});
      expect(report.formattedText, isNot(contains('secret')));
    },
  );

  test(
    'diagnostics failure or timeout does not replace original error',
    () async {
      native.intercept = (call) async {
        if (call.method == 'diagnostics') return Completer<Object?>().future;
        return native.respond(call);
      };
      await player.open(source);
      await emit();
      await player.retry().timeout(const Duration(seconds: 1));
      final report = (await player.failureReport())!;
      expect(report.code, 'network');
      expect(report.metadata['diagnosticsStatus'], 'unavailable');
      expect(report.metadata['native'], isEmpty);
    },
  );

  test('disposed report needs no live engine or pending diagnostics', () async {
    final pending = Completer<Object?>();
    native.intercept = (call) async {
      if (call.method == 'diagnostics') return pending.future;
      return native.respond(call);
    };
    await player.open(source);
    await emit();
    await Future<void>.delayed(const Duration(milliseconds: 5));
    await player.dispose();
    final report = (await player.failureReport().timeout(
      const Duration(milliseconds: 50),
    ))!;
    expect(report.code, 'network');
    expect(report.metadata['diagnosticsStatus'], 'unavailable');
    final count = native.named('diagnostics').length;
    pending.complete({'httpStatus': 503});
    await Future<void>.delayed(Duration.zero);
    expect((await player.failureReport())!.formattedText, report.formattedText);
    expect(native.named('diagnostics'), hasLength(count));
  });

  test('diagnostic exceptions and invalid types remain private', () async {
    native.intercept = (call) async {
      if (call.method == 'diagnostics') {
        throw PlatformException(
          code: 'private-token',
          message: 'password=secret',
        );
      }
      return native.respond(call);
    };
    await player.open(source);
    await emit(
      details: {
        'nativeCode': 'password=secret',
        'recoverable': 'Bearer secret',
        'nativeErrorChain': List.generate(40, (i) => {'code': -1005}),
        'httpStatus': double.nan,
      },
    );
    final report = (await player.failureReport())!;
    expect(report.metadata['diagnosticsStatus'], 'unavailable');
    final details = report.metadata['details'] as Map;
    expect(details.containsKey('nativeCode'), isFalse);
    expect(details.containsKey('httpStatus'), isFalse);
    expect(details.containsKey('recoverable'), isFalse);
    expect(details['nativeErrorChain'], hasLength(30));
    expect(report.formattedText, isNot(contains('secret')));
    expect(report.formattedText, isNot(contains('private-token')));
  });

  test(
    'new failures replace history, old pending diagnostics cannot overwrite',
    () async {
      final pending = Completer<Object?>();
      var count = 0;
      native.intercept = (call) async {
        if (call.method == 'diagnostics') {
          if (count++ == 0) return pending.future;
          return {'httpStatus': 403};
        }
        return native.respond(call);
      };
      await player.open(source);
      await emit();
      await Future<void>.delayed(const Duration(milliseconds: 5));
      await emit(code: 'http_403');
      final report = (await player.failureReport())!;
      pending.complete({'httpStatus': 503});
      await Future<void>.delayed(Duration.zero);
      expect((await player.failureReport())!.code, 'http_403');
      expect((await player.failureReport())!.timestamp, report.timestamp);
      expect((await player.failureReport())!.metadata['native'], {
        'httpStatus': 403,
      });
    },
  );
}
