import 'dart:async';
import 'dart:convert';

import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import 'controller.dart';

/// Opt-in diagnostics. Polls only while mounted and the app is active.
/// Unavailable metrics are not inferred from the source's file extension.
class LumioStatisticsView extends StatefulWidget {
  const LumioStatisticsView({
    super.key,
    required this.controller,
    this.refreshInterval = const Duration(seconds: 2),
    this.showRawDetails = false,
  }) : assert(refreshInterval > Duration.zero);
  final LumioPlayerController controller;
  final Duration refreshInterval;
  final bool showRawDetails;

  static Future<void> show(
    BuildContext context,
    LumioPlayerController controller,
  ) => showDialog<void>(
    context: context,
    builder: (context) => Dialog(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 650, maxHeight: 650),
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: LumioStatisticsView(controller: controller),
        ),
      ),
    ),
  );

  @override
  State<LumioStatisticsView> createState() => _LumioStatisticsViewState();
}

class _LumioStatisticsViewState extends State<LumioStatisticsView>
    with WidgetsBindingObserver {
  Timer? _timer;
  Map<String, dynamic>? _snapshot;
  bool _fetching = false, _failed = false;
  bool _active = true;
  int _generation = 0;
  DateTime? _updated;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _active =
        WidgetsBinding.instance.lifecycleState == null ||
        WidgetsBinding.instance.lifecycleState == AppLifecycleState.resumed;
    _start();
  }

  void _start() {
    _timer?.cancel();
    if (!_active) return;
    unawaited(_refresh());
    _timer = Timer.periodic(
      widget.refreshInterval,
      (_) => unawaited(_refresh()),
    );
  }

  @override
  void didUpdateWidget(LumioStatisticsView oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.controller != widget.controller) {
      ++_generation;
      _fetching = false;
      _snapshot = null;
      _updated = null;
    }
    if (oldWidget.controller != widget.controller ||
        oldWidget.refreshInterval != widget.refreshInterval) {
      _start();
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _active = state == AppLifecycleState.resumed;
    _start();
  }

  Future<void> _refresh() async {
    if (_fetching || !_active) return;
    _fetching = true;
    final generation = _generation;
    try {
      final snapshot = await widget.controller.diagnostics();
      if (!mounted || generation != _generation) return;
      setState(() {
        _snapshot = snapshot;
        _updated = DateTime.now();
        _failed = false;
      });
    } catch (_) {
      if (mounted && generation == _generation) setState(() => _failed = true);
    } finally {
      if (generation == _generation) _fetching = false;
    }
  }

  @override
  void dispose() {
    ++_generation;
    _timer?.cancel();
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    Map map(Object? object) => object is Map ? object : const {};
    final root = _snapshot ?? const <String, dynamic>{};
    final native = map(root['native']);
    final player = native['player'] is Map ? map(native['player']) : native;
    final media = map(native['media']);
    final playback = map(root['playback']);
    final device = map(native['device']);
    final access =
        native['accessLog'] is List && (native['accessLog'] as List).isNotEmpty
        ? map((native['accessLog'] as List).last)
        : const {};
    final rows = <String, Object?>{
      'Engine ativa / solicitada':
          '${root['engine'] ?? '—'} / ${root['requestedEngine'] ?? '—'}',
      'Backend':
          native['backend'] ??
          native['engine'] ??
          (root['engine'] == 'native' ? 'Media3 / AVFoundation' : null),
      'Dispositivo': native['model'] ?? device['model'],
      'Fabricante': native['manufacturer'],
      'Sistema':
          native['androidVersion'] ??
          device['systemVersion'] ??
          native['platform'],
      'API Android': native['sdkInt'],
      'Codec vídeo':
          player['videoCodecs'] ??
          player['videoMimeType'] ??
          media['videoCodec'],
      'Decoder vídeo': player['videoDecoderName'],
      'Codec áudio':
          player['audioCodecs'] ??
          player['audioMimeType'] ??
          media['audioCodec'],
      'Decoder áudio': player['audioDecoderName'],
      'Resolução': playback['width'] != null && (playback['width'] as num) > 0
          ? '${playback['width']} × ${playback['height']}'
          : null,
      'FPS da faixa': player['frameRate'] ?? media['frameRate'],
      'Bitrate vídeo (bit/s)': player['videoBitrate'] ?? media['videoBitrate'],
      'Bitrate áudio (bit/s)': player['audioBitrate'] ?? media['audioBitrate'],
      'Bitrate observado (bit/s)': access['observedBitrate'],
      'Frames renderizados': player['renderedVideoFrames'],
      'Frames totais (browser)': media['totalVideoFrames'],
      'Bitrate da variante HLS (bit/s)': media['declaredVariantBitrate'],
      'Frames descartados':
          player['droppedVideoFrames'] ?? media['droppedVideoFrames'],
      'Fonte / hint de formato':
          '${playback['sourceType'] ?? '—'} / ${playback['formatHint'] ?? '—'}',
      'Ao vivo': playback['live'],
      'Buffer à frente (ms)':
          player['bufferDurationMs'] ?? playback['bufferAheadMs'],
      'Distância do live (ms)': player['liveOffsetMs'],
      'Buffering': playback['buffering'],
      'Posição / duração (ms)':
          '${playback['positionMs'] ?? '—'} / ${playback['durationMs'] ?? '—'}',
      'Velocidade': playback['speed'],
      'Stalls (AVPlayer)': access['numberOfStalls'],
      'Fallback utilizado': root['fallbackUsed'],
      'Último erro': playback['lastErrorCode'],
    };
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        Row(
          children: [
            const Expanded(
              child: Text(
                'Estatísticas para nerds',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            IconButton(
              tooltip: 'Atualizar estatísticas',
              onPressed: () => unawaited(_refresh()),
              icon: const Icon(Icons.refresh),
            ),
            IconButton(
              tooltip: 'Copiar diagnóstico sanitizado',
              onPressed: _snapshot == null
                  ? null
                  : () async {
                      try {
                        await Clipboard.setData(
                          ClipboardData(
                            text: const JsonEncoder.withIndent(
                              '  ',
                            ).convert(_snapshot),
                          ),
                        );
                      } catch (_) {
                        /* Clipboard availability must not affect playback. */
                      }
                    },
              icon: const Icon(Icons.copy),
            ),
          ],
        ),
        if (_failed)
          const Text(
            'Não foi possível atualizar. O último snapshot pode estar desatualizado.',
          ),
        if (_snapshot == null && !_failed) const LinearProgressIndicator(),
        if (_updated != null)
          Text(
            'Atualizado: ${_updated!.toLocal().toIso8601String()}',
            style: Theme.of(context).textTheme.labelSmall,
          ),
        const Text(
          '— = indisponível nesta engine/fonte. FPS da faixa não é FPS de renderização. Sem upload automático.',
          style: TextStyle(fontSize: 11),
        ),
        Flexible(
          child: SingleChildScrollView(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: [
                for (final row in rows.entries)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 3),
                    child: Text(
                      '${row.key}: ${row.value ?? '—'}',
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        fontSize: 12,
                      ),
                    ),
                  ),
                if (widget.showRawDetails)
                  SelectableText(
                    const JsonEncoder.withIndent('  ').convert(_snapshot),
                  ),
              ],
            ),
          ),
        ),
      ],
    );
  }
}
