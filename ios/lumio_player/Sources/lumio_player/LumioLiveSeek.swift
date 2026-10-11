import CoreMedia

// Recovery requires media evidence, independently of the configuration hint.
// A finite range strictly inside the VOD timeline is not a live window candidate.
private func lumioHasLiveWindowCandidate(duration: CMTime, ranges: [CMTimeRange]) -> Bool {
  if duration.isIndefinite { return true }
  guard duration.isNumeric, CMTimeCompare(duration, .zero) > 0,
        let range = ranges.last, range.isValid, !range.isEmpty,
        range.start.isNumeric, range.duration.isNumeric,
        CMTimeCompare(range.start, .zero) > 0 else { return false }
  let end = CMTimeRangeGetEnd(range)
  return end.isNumeric && CMTimeCompare(end, duration) >= 0
}

struct LumioLiveTimeline {
  private var previousWindow: CMTimeRange?

  mutating func observe(duration: CMTime, ranges: [CMTimeRange]) -> Bool {
    if duration.isIndefinite { return true }
    guard lumioHasLiveWindowCandidate(duration: duration, ranges: ranges),
          let window = ranges.last else { return false }
    let previous = previousWindow
    previousWindow = window
    // A single finite suffix of VOD is ambiguous. Require a moving window,
    // not merely a positive start or the host's live hint.
    guard let previous = previous else { return false }
    return CMTimeCompare(window.start, previous.start) > 0 &&
      CMTimeCompare(CMTimeRangeGetEnd(window), CMTimeRangeGetEnd(previous)) > 0
  }
}

// AVPlayer has no universal live flag. An explicit hint permits finite-duration
// sliding windows, but must not turn an ordinary full-timeline VOD into live.
func lumioLiveSeekTarget(duration: CMTime, ranges: [CMTimeRange], liveHint: Bool) throws -> CMTime {
  guard let range = ranges.last, range.isValid, !range.isEmpty,
        range.start.isNumeric, range.duration.isNumeric else {
    throw LumioFailure("unsupported_live_seek", "No valid live seekable range is available.")
  }
  let end = CMTimeRangeGetEnd(range)
  guard end.isNumeric else {
    throw LumioFailure("unsupported_live_seek", "The live seekable range has no finite end.")
  }
  let hintedSlidingWindow = liveHint && duration.isNumeric &&
    CMTimeCompare(duration, .zero) > 0 && CMTimeCompare(range.start, .zero) > 0
  guard duration.isIndefinite || hintedSlidingWindow else {
    throw LumioFailure("unsupported_live_seek", "Live seek requires an indefinite duration or an explicitly hinted finite sliding window; ordinary VOD is unsupported.")
  }
  let target = CMTimeSubtract(end, CMTime(seconds: 0.5, preferredTimescale: 1000))
  return CMTimeCompare(target, range.start) < 0 ? range.start : target
}
