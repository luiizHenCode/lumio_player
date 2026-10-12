import CoreMedia
import Foundation

func lumioMilliseconds(_ time: CMTime) -> Int64 {
  let value = CMTimeGetSeconds(time) * 1000
  guard time.isNumeric, value.isFinite, value > 0 else { return 0 }
  return Int64(min(value, Double(Int64.max / 2)))
}

// Preserve separate timeline intervals (including nonzero live-window starts).
// Invalid/empty intervals must not become a fictitious range starting at zero.
func lumioBufferedRanges(_ ranges: [CMTimeRange]) -> [[String: Int64]] {
  ranges.compactMap { range in
    let end = CMTimeRangeGetEnd(range)
    guard range.isValid, !range.isEmpty, range.start.isNumeric,
          range.duration.isNumeric, end.isNumeric,
          CMTimeGetSeconds(range.start).isFinite, CMTimeGetSeconds(end).isFinite,
          CMTimeCompare(range.start, .zero) >= 0,
          CMTimeCompare(range.duration, .zero) > 0 else { return nil }
    return ["startMs": lumioMilliseconds(range.start), "endMs": lumioMilliseconds(end)]
  }
}
