import 'dart:async';
import 'dart:convert';
import 'dart:ui' show Color;

import 'package:flutter/foundation.dart';
import 'package:webview_flutter/webview_flutter.dart';
import 'package:webview_flutter_android/webview_flutter_android.dart';
import 'package:webview_flutter_wkwebview/webview_flutter_wkwebview.dart';

import 'models.dart';

/// Network-only HTML media engine. Mount [controller] in a WebViewWidget before
/// awaiting [open]. Register assets/web/ in the lumio_player package manifest.
class LumioWebEngine {
  LumioWebEngine({required this._onEvent}) {
    PlatformWebViewControllerCreationParams params =
        const PlatformWebViewControllerCreationParams();
    if (WebViewPlatform.instance is WebKitWebViewPlatform) {
      params = WebKitWebViewControllerCreationParams(
        allowsInlineMediaPlayback: true,
        mediaTypesRequiringUserAction: const <PlaybackMediaTypes>{},
      );
    }
    _controller = WebViewController.fromPlatformCreationParams(params);
    unawaited(_prepare());
  }

  static const _asset = 'packages/lumio_player/assets/web/player.html';
  final void Function(Map<String, dynamic>) _onEvent;
  late final WebViewController _controller;
  final Completer<void> _ready = Completer<void>();
  final Map<int, Completer<Object?>> _pending = {};
  Map<String, dynamic> _state = {};
  bool _disposed = false;
  Future<void>? _disposal;
  bool _mounted = false;
  int _sequence = 0;
  Duration _commandTimeout = const Duration(seconds: 25);
  int? _opening;
  int _openGeneration = 0;
  String? _setupError;
  String? _sourceFormat;

  WebViewController get controller => _controller;

  /// Optional diagnostic hint; readiness is determined by the JS handshake.
  void acknowledgeMounted() => _mounted = true;

  Map<String, Object?> get diagnostics => {
    'engine': 'webview',
    'platform': defaultTargetPlatform.name,
    'disposed': _disposed,
    'mountedAcknowledged': _mounted,
    'bridgeReady': _ready.isCompleted && _setupError == null,
    'sourceType': _sourceFormat == null ? null : 'network',
    'format': _sourceFormat,
    'pendingRequests': _pending.length,
    'state': Map<String, dynamic>.unmodifiable(_state),
    'media': _state['media'],
    'decoderName': null,
    'setupError': _setupError,
  };

  Future<void> _prepare() async {
    try {
      await _controller.setJavaScriptMode(JavaScriptMode.unrestricted);
      await _controller.setBackgroundColor(const Color(0xFF000000));
      await _controller.addJavaScriptChannel(
        'LumioBridge',
        onMessageReceived: _receive,
      );
      await _controller.setNavigationDelegate(
        NavigationDelegate(
          onNavigationRequest: (request) {
            final uri = Uri.tryParse(request.url);
            return !_ready.isCompleted &&
                    uri != null &&
                    uri.scheme == 'file' &&
                    uri.path.endsWith('/$_asset')
                ? NavigationDecision.navigate
                : NavigationDecision.prevent;
          },
          onWebResourceError: (error) {
            if (error.isForMainFrame == true && !_ready.isCompleted) {
              _setupError = 'webview_load_failed';
              _ready.complete();
            }
          },
        ),
      );
      final platform = _controller.platform;
      if (platform is AndroidWebViewController) {
        await platform.setMediaPlaybackRequiresUserGesture(false);
      }
      if (!_disposed) await _controller.loadFlutterAsset(_asset);
    } catch (_) {
      _setupError = 'webview_setup_failed';
      if (!_ready.isCompleted) _ready.complete();
    }
  }

  void _receive(JavaScriptMessage message) {
    try {
      final event = jsonDecode(message.message) as Map<String, dynamic>;
      if (_disposed && event['type'] != 'ack') return;
      switch (event['type']) {
        case 'ready':
          if (!_ready.isCompleted) _ready.complete();
          return;
        case 'ack':
          final pending = _pending.remove(event['request']);
          if (pending != null) {
            if (event['ok'] == true) {
              pending.complete(event['data']);
            } else {
              pending.completeError(
                LumioPlayerError(
                  code: event['code'] as String? ?? 'media_failed',
                  message:
                      'The WebView could not complete the media operation.',
                  engine: LumioPlaybackEngine.webview,
                ),
              );
            }
          }
          return;
        case 'state':
          _state = Map<String, dynamic>.from(event);
          break;
        case 'error':
          break;
        default:
          return;
      }
      _onEvent(event);
    } catch (_) {
      // Ignore malformed bridge messages without exposing source information.
    }
  }

  Never _fail(String code, String message, {bool recoverable = false}) {
    if (!_disposed) {
      _onEvent({
        'type': 'error',
        'code': code,
        'message': message,
        'details': <String, Object?>{'engine': 'webview'},
        'recoverable': recoverable,
      });
    }
    throw LumioPlayerError(
      code: code,
      message: message,
      recoverable: recoverable,
      engine: LumioPlaybackEngine.webview,
    );
  }

  void _checkActive() {
    if (_disposed) throw StateError('disposed');
  }

  /// [config] accepts live, autoPlay, looping, volume, speed and
  /// initializationTimeoutMs (default 25000, range 1..120000) and
  /// commandTimeoutMs (positive, defaults to initializationTimeoutMs).
  Future<void> open(
    Map<String, Object?> source,
    Map<String, Object?> config,
  ) async {
    _checkActive();
    final uri = source['uri'] is String
        ? Uri.tryParse(source['uri']! as String)
        : null;
    if (source['type'] != 'network' ||
        uri == null ||
        !const ['http', 'https'].contains(uri.scheme) ||
        uri.host.isEmpty ||
        uri.userInfo.isNotEmpty) {
      _fail(
        'unsupported_source',
        'Only HTTP(S) network sources without URL credentials are supported.',
      );
    }
    final headers = source['headers'];
    if (headers != null && (headers is! Map || headers.isNotEmpty)) {
      _fail(
        'unsupported_headers',
        'Custom request headers are not supported by the WebView engine.',
      );
    }
    final format = source['format'] ?? 'auto';
    if (!const ['auto', 'hls', 'progressive'].contains(format)) {
      _fail(
        'unsupported_format',
        'This engine supports auto, HLS and progressive media only.',
      );
    }
    final timeoutMs = config['initializationTimeoutMs'] ?? 25000;
    if (timeoutMs is! int || timeoutMs < 1 || timeoutMs > 120000) {
      _fail(
        'invalid_argument',
        'initializationTimeoutMs must be between 1 and 120000.',
      );
    }
    final commandTimeoutMs = config['commandTimeoutMs'] ?? timeoutMs;
    if (commandTimeoutMs is! int || commandTimeoutMs < 1) {
      _fail('invalid_argument', 'commandTimeoutMs must be positive.');
    }
    _commandTimeout = Duration(milliseconds: commandTimeoutMs);
    for (final key in ['live', 'autoPlay', 'looping']) {
      if (config[key] != null && config[key] is! bool) {
        _fail('invalid_argument', '$key must be a boolean.');
      }
    }
    _validateNumber(config['volume'] ?? 1, 'volume', 0, 1);
    _validateNumber(config['speed'] ?? 1, 'speed', 0.25, 4);
    final generation = ++_openGeneration;
    _cancelOpen();
    _sourceFormat = format as String;
    final watch = Stopwatch()..start();
    final limit = Duration(milliseconds: timeoutMs);
    try {
      await _ready.future.timeout(limit);
      _checkActive();
      if (generation != _openGeneration) throw StateError('open_cancelled');
      if (_setupError != null) {
        _fail(_setupError!, 'Unable to load the bundled player.');
      }
      final id = ++_sequence;
      _opening = id;
      await _request(id, 'open', {
        'uri': uri.toString(),
        'format': format,
        'live': config['live'] ?? false,
        'autoPlay': config['autoPlay'] ?? true,
        'looping': config['looping'] ?? false,
        'volume': config['volume'] ?? 1,
        'speed': config['speed'] ?? 1,
        'fit': config['fit'] ?? 'contain',
      }).timeout(limit - watch.elapsed);
    } on TimeoutException {
      if (!_disposed && generation == _openGeneration) {
        _cancelOpen();
        unawaited(_send({'method': 'reset'}).catchError((Object _) {}));
        _fail(
          'initialization_timeout',
          'Mount the WebView while opening; bridge or media metadata timed out.',
          recoverable: true,
        );
      }
      rethrow;
    } finally {
      if (generation == _openGeneration) _opening = null;
    }
  }

  void _validateNumber(Object? value, String name, double min, double max) {
    if (value is! num || !value.isFinite || value < min || value > max) {
      _fail(
        'invalid_argument',
        '$name must be a finite number between $min and $max.',
      );
    }
  }

  Future<void> setFit(String fit) async {
    await _ready.future.timeout(_commandTimeout);
    await command('fit', {'fit': fit});
  }

  Future<void> command(
    String method, [
    Map<String, Object?> arguments = const {},
  ]) async {
    _checkActive();
    if (!const [
      'play',
      'pause',
      'seek',
      'seekToLive',
      'volume',
      'speed',
      'looping',
      'fit',
    ].contains(method)) {
      _fail('unsupported_command', 'Unsupported media command.');
    }
    final args = <String, Object?>{};
    if (method == 'fit') {
      final fit = arguments['fit'];
      if (!const [
        'contain',
        'cover',
        'fill',
        'fitWidth',
        'fitHeight',
        'none',
        'scaleDown',
      ].contains(fit)) {
        _fail('invalid_argument', 'Unknown video fit.');
      }
      args['fit'] = fit;
    } else if (method == 'seek') {
      _validateNumber(
        arguments['positionMs'],
        'positionMs',
        0,
        9007199254740991,
      );
      args['positionMs'] = arguments['positionMs'];
    } else if (method == 'volume' || method == 'speed') {
      final value = arguments[method] ?? arguments['value'];
      _validateNumber(
        value,
        method,
        method == 'volume' ? 0 : 0.25,
        method == 'volume' ? 1 : 4,
      );
      args['value'] = value;
    } else if (method == 'looping') {
      final value = arguments['looping'] ?? arguments['value'];
      if (value is! bool) {
        _fail('invalid_argument', 'looping must be a boolean.');
      }
      args['value'] = value;
    }
    if (!_ready.isCompleted || _setupError != null) {
      _fail('not_ready', 'The player bridge is not ready.');
    }
    final id = ++_sequence;
    try {
      await _request(id, method, args).timeout(_commandTimeout);
    } on TimeoutException {
      _pending.remove(id);
      _fail(
        'command_timeout',
        'The media command timed out.',
        recoverable: true,
      );
    }
  }

  Future<Object?> getPosition() async {
    _checkActive();
    final id = ++_sequence;
    try {
      return await _request(
        id,
        'getPosition',
        const {},
      ).timeout(_commandTimeout);
    } finally {
      _pending.remove(id);
    }
  }

  Future<Object?> _request(
    int id,
    String method,
    Map<String, Object?> args,
  ) async {
    final completer = Completer<Object?>();
    _pending[id] = completer;
    // Attach the listener before dispatch: disposal may cancel during dispatch.
    final result = completer.future;
    unawaited(
      _send({'request': id, 'method': method, 'arguments': args}).catchError((
        Object _,
      ) {
        final pending = _pending.remove(id);
        pending?.completeError(StateError('bridge_dispatch_failed'));
      }),
    );
    return await result;
  }

  Future<void> _send(Map<String, Object?> payload) {
    // Encode twice: the payload is a JS string literal, never executable HTML.
    final literal = jsonEncode(
      jsonEncode(payload),
    ).replaceAll('\u2028', r'\u2028').replaceAll('\u2029', r'\u2029');
    return _controller.runJavaScript(
      'window.LumioPlayer.receive(JSON.parse($literal));',
    );
  }

  void _cancelOpen() {
    final id = _opening;
    if (id != null) {
      _pending.remove(id)?.completeError(StateError('open_cancelled'));
    }
    _opening = null;
  }

  Future<void> dispose() {
    if (_disposal != null) return _disposal!;
    _disposed = true;
    ++_openGeneration;
    for (final pending in _pending.values) {
      pending.completeError(StateError('disposed'));
    }
    _pending.clear();
    if (!_ready.isCompleted) _ready.complete();
    return _disposal = _disposeMedia();
  }

  Future<void> _disposeMedia() async {
    final id = ++_sequence;
    try {
      // Dispatch alone does not prove pause/HLS teardown completed in the page.
      await _request(
        id,
        'dispose',
        const {},
      ).timeout(const Duration(seconds: 2));
    } finally {
      _pending.remove(id);
      _state = {};
      // WebView has no explicit native-controller disposal API. Detaching its
      // widget still belongs to the host; this ACK confirms media cleanup only.
    }
  }
}
