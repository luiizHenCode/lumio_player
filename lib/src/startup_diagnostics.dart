import 'models.dart';

/// Internal monotonic clock. Each getter returns an independent frozen snapshot.
class LumioStartupDiagnostics {
  LumioStartupDiagnostics(
    this.attempt, {
    required this.recovering,
    Stopwatch? clock,
  }) : _clock = clock ?? (Stopwatch()..start()) {
    stage(
      recovering
          ? LumioPlaybackPhase.recovering
          : LumioPlaybackPhase.connecting,
    );
  }

  final int attempt;
  final bool recovering;
  final Stopwatch _clock;
  final List<Map<String, Object?>> _events = [];
  LumioPlaybackPhase _stage = LumioPlaybackPhase.idle;
  int? createElapsedMs,
      readinessElapsedMs,
      firstFrameElapsedMs,
      playbackStartedElapsedMs;
  LumioFirstFrameEvidence? evidence;

  void stage(LumioPlaybackPhase stage) {
    if (_events.isNotEmpty && _stage == stage) return;
    _stage = stage;
    if (_events.length == 32) _events.removeAt(0);
    _events.add(
      Map.unmodifiable({
        'stage': stage.name,
        'elapsedMs': _clock.elapsedMilliseconds,
      }),
    );
  }

  void stop() => _clock.stop();

  void created() {
    createElapsedMs ??= _clock.elapsedMilliseconds;
    stage(
      recovering ? LumioPlaybackPhase.recovering : LumioPlaybackPhase.preparing,
    );
  }

  void observe(LumioPlayerState state) {
    if (state.initialized) readinessElapsedMs ??= _clock.elapsedMilliseconds;
    if (state.hasRenderedFirstFrame) {
      firstFrameElapsedMs ??= _clock.elapsedMilliseconds;
      evidence ??= state.firstFrameEvidence;
    }
    // Playback signal is separate from rendering evidence.
    if (state.playing) playbackStartedElapsedMs ??= _clock.elapsedMilliseconds;
    stage(state.phase);
  }

  Map<String, Object?> get snapshot => Map.unmodifiable({
    'attempt': attempt,
    'stage': _stage.name,
    'evidence': evidence?.name,
    'createElapsedMs': createElapsedMs,
    'readinessElapsedMs': readinessElapsedMs,
    'firstFrameElapsedMs': firstFrameElapsedMs,
    'playbackStartedElapsedMs': playbackStartedElapsedMs,
    'elapsedMs': _clock.elapsedMilliseconds,
    'events': List<Map<String, Object?>>.unmodifiable(_events),
  });
}
