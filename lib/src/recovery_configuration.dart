/// Opt-in recovery for requested live network playback.
/// Position progress is a stall heuristic, not a video-frame health signal.
class LumioRecoveryConfiguration {
  const LumioRecoveryConfiguration({
    this.enabled = false,
    this.maxAttempts = 3,
    this.initialDelay = const Duration(seconds: 1),
    this.maxDelay = const Duration(seconds: 15),
    this.stallTimeout = const Duration(seconds: 20),
    this.stablePlaybackDuration = const Duration(seconds: 30),
  });

  final bool enabled;
  final int maxAttempts;
  final Duration initialDelay, maxDelay, stallTimeout, stablePlaybackDuration;

  void validate() {
    if (maxAttempts < 1 ||
        initialDelay <= Duration.zero ||
        maxDelay < initialDelay ||
        stallTimeout <= Duration.zero ||
        stablePlaybackDuration <= Duration.zero) {
      throw ArgumentError(
        'Recovery requires maxAttempts >= 1, 0 < initialDelay <= maxDelay, '
        'and positive stall/stable durations.',
      );
    }
  }
}
