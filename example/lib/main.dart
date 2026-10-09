import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:lumio_player/lumio_player.dart';

void main() => runApp(const LumioDemoApp());

class LumioDemoApp extends StatelessWidget {
  const LumioDemoApp({super.key});

  @override
  Widget build(BuildContext context) => MaterialApp(
    title: 'Lumio Player',
    theme: ThemeData(useMaterial3: true, colorSchemeSeed: Colors.indigo),
    home: const PlayerDemo(),
  );
}

class PlayerDemo extends StatefulWidget {
  const PlayerDemo({super.key});

  @override
  State<PlayerDemo> createState() => _PlayerDemoState();
}

class _PlayerDemoState extends State<PlayerDemo> {
  final _input = TextEditingController(
    text: 'https://flutter.github.io/assets-for-api-docs/assets/videos/bee.mp4',
  );
  final _assetPackage = TextEditingController();
  final _headers = TextEditingController();
  bool _showControls = true, _compact = false, _zoom = false;
  BoxFit _fit = BoxFit.contain;
  double? _aspectRatio;
  final Set<double> _speeds = {1, 1.5, 2, 3, 4};
  final _logs = <String>[];
  late LumioPlayerController _controller;
  LumioSourceType _sourceType = LumioSourceType.network;
  LumioPlaybackMode _mode = LumioPlaybackMode.video;
  LumioPlaybackEngine _engine = LumioPlaybackEngine.automatic;
  String _diagnostics = 'No diagnostics collected.';
  String? _feedback;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _controller = _createController();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) unawaited(_open());
    });
  }

  // Defense in depth: never display URLs, source paths or header values even
  // if a future engine returns unsanitized diagnostic strings.
  String _sanitize(String text) {
    var result = text;
    final source = _controller.source;
    if (source != null) {
      result = result.replaceAll(source.uri, '[source]');
      for (final value in source.headers.values) {
        if (value.isNotEmpty) result = result.replaceAll(value, '[redacted]');
      }
    }
    return result.replaceAll(
      RegExp(r'(?:https?|rtsp|file)://[^\s\]\)"\x27]+'),
      '[url]',
    );
  }

  LumioPlayerController _createController() => LumioPlayerController(
    configuration: LumioPlayerConfiguration(mode: _mode, engine: _engine),
    logger: (entry) {
      if (!mounted) return;
      setState(() {
        _logs.insert(0, _sanitize(entry.toString()));
        if (_logs.length > 80) _logs.removeLast();
      });
    },
  );

  LumioSource _source() {
    final input = _input.text.trim();
    if (input.isEmpty) {
      throw ArgumentError('Enter a URL, file path or asset key.');
    }
    return switch (_sourceType) {
      LumioSourceType.network => LumioSource.network(Uri.parse(input)),
      LumioSourceType.file => LumioSource.file(input),
      LumioSourceType.asset => LumioSource.asset(
        input,
        package: _assetPackage.text.trim().isEmpty
            ? null
            : _assetPackage.text.trim(),
      ),
    };
  }

  Future<void> _open() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _feedback = null;
    });
    try {
      final source = _source();
      if (_controller.configuration.mode != _mode) {
        final previous = _controller;
        setState(() {
          _controller = _createController();
        });
        // Unmount the previous surface and mount the replacement before open.
        await WidgetsBinding.instance.endOfFrame;
        await previous.dispose();
      }
      if (!mounted) return;
      if (_controller.requestedEngine != _engine) {
        await _controller.setEngine(_engine);
      }
      final rawHeaders = _headers.text.trim();
      final headers = rawHeaders.isEmpty
          ? <String, String>{}
          : Map<String, String>.from(jsonDecode(rawHeaders) as Map);
      await _controller.open(source, headers: headers, title: 'Lumio demo');
    } catch (error) {
      if (mounted) {
        setState(() {
          _feedback = _failure(error);
        });
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
        });
      }
    }
  }

  Future<void> _openDemoPlaylist() async {
    if (_busy) return;
    setState(() => _busy = true);
    try {
      await _controller.openPlaylist(
        LumioPlaylist([
          LumioPlaylistItem(
            source: LumioSource.asset('assets/sample.mp4'),
            title: 'Vídeo sintético — primeiro',
          ),
          LumioPlaylistItem(
            source: LumioSource.asset('assets/sample.mp4'),
            title: 'Vídeo sintético — segundo',
          ),
        ], loop: true),
      );
    } catch (error) {
      if (mounted) setState(() => _feedback = _failure(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String _failure(Object error) => error is LumioPlayerError
      ? 'Playback failed (${_sanitize(error.code)}). Check diagnostics or retry.'
      : 'Operation failed. Check your source, platform support and connection.';

  Future<void> _inspect() async {
    try {
      final data = await _controller.diagnostics();
      if (mounted) {
        setState(() {
          _diagnostics = _sanitize(
            const JsonEncoder.withIndent('  ').convert(data),
          );
        });
      }
    } catch (error) {
      if (mounted) {
        setState(() {
          _feedback = _failure(error);
        });
      }
    }
  }

  Future<void> _disposeController() async {
    try {
      await _controller.dispose();
    } catch (_) {
      // No UI remains to report a teardown error.
    }
  }

  @override
  void dispose() {
    _input.dispose();
    _assetPackage.dispose();
    _headers.dispose();
    unawaited(_disposeController());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    appBar: AppBar(title: const Text('Lumio Player')),
    body: SingleChildScrollView(
      padding: const EdgeInsets.all(16),
      child: Center(
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 900),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: [
              LumioPlayerView(
                key: ObjectKey(_controller),
                controller: _controller,
                fit: _fit,
                aspectRatio: _aspectRatio,
                controls: _showControls,
                controlsConfiguration: LumioControlsConfiguration(
                  showStatistics: true,
                  compact: _compact,
                  enableZoom: _zoom,
                  playbackSpeeds: _speeds.toList()..sort(),
                  progressColor: const Color(0xff9976bd),
                ),
              ),
              Wrap(
                spacing: 12,
                children: [
                  FilterChip(
                    label: const Text('Controles'),
                    selected: _showControls,
                    onSelected: (value) =>
                        setState(() => _showControls = value),
                  ),
                  FilterChip(
                    label: const Text('Compacto (2s)'),
                    selected: _compact,
                    onSelected: (value) => setState(() => _compact = value),
                  ),
                  FilterChip(
                    label: const Text('Zoom até 4x'),
                    selected: _zoom,
                    onSelected: (value) => setState(() => _zoom = value),
                  ),
                  for (final speed in const [1.0, 1.5, 2.0, 3.0, 4.0])
                    FilterChip(
                      label: Text('${speed}x'),
                      selected: _speeds.contains(speed),
                      onSelected: (selected) => setState(() {
                        if (selected) {
                          _speeds.add(speed);
                        } else if (_speeds.length > 1) {
                          _speeds.remove(speed);
                        }
                      }),
                    ),
                ],
              ),
              const SizedBox(height: 16),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: [
                  _picker<BoxFit>(
                    'Video fit',
                    _fit,
                    BoxFit.values,
                    (value) => setState(() => _fit = value),
                  ),
                  SizedBox(
                    width: 210,
                    child: DropdownButtonFormField<double>(
                      decoration: const InputDecoration(
                        labelText: 'Aspect ratio',
                        border: OutlineInputBorder(),
                      ),
                      initialValue: _aspectRatio ?? 0,
                      items: const [
                        DropdownMenuItem(value: 0, child: Text('Original')),
                        DropdownMenuItem(value: 16 / 9, child: Text('16:9')),
                        DropdownMenuItem(value: 4 / 3, child: Text('4:3')),
                        DropdownMenuItem(value: 1, child: Text('1:1')),
                        DropdownMenuItem(value: 9 / 16, child: Text('9:16')),
                      ],
                      onChanged: (value) => setState(
                        () => _aspectRatio = value == 0 ? null : value,
                      ),
                    ),
                  ),
                  _picker<LumioSourceType>(
                    'Source',
                    _sourceType,
                    LumioSourceType.values,
                    (value) => setState(() {
                      _sourceType = value;
                    }),
                  ),
                  _picker<LumioPlaybackMode>(
                    'Mode',
                    _mode,
                    LumioPlaybackMode.values,
                    (value) => setState(() {
                      _mode = value;
                    }),
                  ),
                  _picker<LumioPlaybackEngine>(
                    'Engine for next open',
                    _engine,
                    LumioPlaybackEngine.values,
                    (value) => setState(() {
                      _engine = value;
                    }),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _input,
                enabled: !_busy,
                autocorrect: false,
                enableSuggestions: false,
                decoration: InputDecoration(
                  border: const OutlineInputBorder(),
                  labelText: switch (_sourceType) {
                    LumioSourceType.network => 'Network URL',
                    LumioSourceType.file => 'Absolute device file path',
                    LumioSourceType.asset => 'Bundled asset key',
                  },
                ),
                onSubmitted: (_) => unawaited(_open()),
              ),
              if (_sourceType == LumioSourceType.network) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _headers,
                  obscureText: true,
                  autocorrect: false,
                  enableSuggestions: false,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Headers JSON (Android nativo)',
                    helperText:
                        'Ex.: {"Authorization":"Bearer …"}. iOS/WebView: use URL assinada.',
                  ),
                ),
              ],
              if (_sourceType == LumioSourceType.asset) ...[
                const SizedBox(height: 12),
                TextField(
                  controller: _assetPackage,
                  enabled: !_busy,
                  decoration: const InputDecoration(
                    border: OutlineInputBorder(),
                    labelText: 'Asset package (optional)',
                  ),
                ),
              ],
              const SizedBox(height: 12),
              const Text(
                'File paths refer to this device, not your development machine. '
                'Assets must be declared in the consuming app. WebView supports '
                'HTTP(S) progressive/HLS sources only. Use HTTPS; cleartext HTTP '
                'may be blocked by the platform. Network playback contacts the supplied host.',
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: [
                  FilledButton.icon(
                    onPressed: _busy ? null : () => unawaited(_open()),
                    icon: const Icon(Icons.open_in_new),
                    label: Text(_busy ? 'Opening…' : 'Open source'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy
                        ? null
                        : () => unawaited(_openDemoPlaylist()),
                    icon: const Icon(Icons.playlist_play),
                    label: const Text('Playlist de exemplo'),
                  ),
                  OutlinedButton.icon(
                    onPressed: _busy ? null : () => unawaited(_inspect()),
                    icon: const Icon(Icons.bug_report_outlined),
                    label: const Text('Diagnostics'),
                  ),
                ],
              ),
              if (_feedback != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(
                    _feedback!,
                    semanticsLabel: 'Player feedback: $_feedback',
                  ),
                ),
              const SizedBox(height: 16),
              Text(
                'Diagnostics (sanitized)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              SelectableText(_diagnostics),
              const SizedBox(height: 16),
              Text(
                'Recent logs (sanitized)',
                style: Theme.of(context).textTheme.titleMedium,
              ),
              if (_logs.isEmpty) const Text('No logs yet.'),
              for (final log in _logs)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 3),
                  child: SelectableText(log),
                ),
            ],
          ),
        ),
      ),
    ),
  );

  Widget _picker<T extends Enum>(
    String label,
    T value,
    List<T> options,
    ValueChanged<T> change,
  ) => SizedBox(
    width: 210,
    child: DropdownButtonFormField<T>(
      initialValue: value,
      isExpanded: true,
      decoration: InputDecoration(
        labelText: label,
        border: const OutlineInputBorder(),
      ),
      items: [
        for (final option in options)
          DropdownMenuItem(value: option, child: Text(option.name)),
      ],
      onChanged: _busy
          ? null
          : (selected) {
              if (selected != null) change(selected);
            },
    ),
  );
}
