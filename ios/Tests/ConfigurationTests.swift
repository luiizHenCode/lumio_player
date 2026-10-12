import CoreMedia
import Foundation

// A host-runnable executable testing the production argument parser, without
// requiring Flutter.framework, a simulator, or network playback.
@main
struct ConfigurationTests {
  static func main() throws {
    try testViewTypeAndTimeline()
    let defaults = try LumioConfiguration([:])
    precondition(!defaults.live && !defaults.autoPlay && !defaults.looping && !defaults.loopPlaylist)
    precondition(defaults.volume == 1 && defaults.speed == 1 && defaults.buffers.isEmpty)
    precondition(defaults.liveTargetOffsetMs == nil && defaults.enableDecoderFallback == nil)

    let values = try LumioConfiguration([
      "live": true, "autoPlay": true, "looping": true, "loopPlaylist": true, "volume": 0.25, "speed": 1.5,
      "bufferMinMs": 500, "bufferMaxMs": 5000,
      "bufferPlaybackMs": 100, "bufferRebufferMs": 1000,
      "liveTargetOffsetMs": 2500, "enableDecoderFallback": true
    ])
    precondition(values.live && values.autoPlay && values.looping && values.loopPlaylist)
    precondition(values.volume == 0.25 && values.speed == 1.5)
    precondition(values.buffers.count == 4 && values.buffers["bufferMaxMs"] == 5000)
    precondition(values.liveTargetOffsetMs == 2500 && values.enableDecoderFallback == true)

    let valid: [[String: Any]] = [
      ["volume": 0], ["volume": 1], ["speed": 0.01], ["speed": 4],
      ["bufferMinMs": 0, "bufferMaxMs": 0], ["bufferMaxMs": 86_400_000],
      ["live": NSNumber(value: false)], ["autoPlay": NSNumber(value: true)],
      ["liveTargetOffsetMs": 0], ["liveTargetOffsetMs": 60_000],
      ["enableDecoderFallback": false]
    ]
    for map in valid { _ = try LumioConfiguration(map) }

    let invalid: [[String: Any]] = [
      ["volume": -0.01], ["volume": 1.01], ["volume": true], ["volume": "1"],
      ["volume": Double.nan], ["volume": Double.infinity], ["volume": NSNull()],
      ["speed": 0], ["speed": -1], ["speed": 4.01], ["speed": false],
      ["speed": Double.nan], ["speed": Double.infinity],
      ["live": 1], ["autoPlay": 0], ["looping": "true"], ["looping": NSNull()],
      ["bufferMinMs": -1], ["bufferMaxMs": 86_400_001],
      ["bufferPlaybackMs": true], ["bufferRebufferMs": Double.infinity],
      ["bufferMinMs": 1000, "bufferMaxMs": 500],
      ["liveTargetOffsetMs": -1], ["liveTargetOffsetMs": 60_001],
      ["liveTargetOffsetMs": true], ["liveTargetOffsetMs": "500"],
      ["liveTargetOffsetMs": Double.nan], ["liveTargetOffsetMs": Double.infinity],
      ["enableDecoderFallback": 1], ["enableDecoderFallback": "true"],
      ["enableDecoderFallback": NSNull()], ["loopPlaylist": 1],
            ["loopPlaylist": "true"], ["loopPlaylist": NSNull()]
    ]
    for map in invalid {
      do {
        _ = try LumioConfiguration(map)
        fatalError("Accepted invalid configuration: \(map)")
      } catch let failure as LumioFailure {
        precondition(failure.code == "invalid_argument")
      }
    }

    let position = try lumioNumber(["positionMs": 1234.5], "positionMs", minimum: 0)
    precondition(position == 1234.5)
    for value: Any in [true, -1, Double.nan, Double.infinity, "100"] {
      do {
        _ = try lumioNumber(["positionMs": value], "positionMs", minimum: 0)
        fatalError("Accepted invalid position: \(value)")
      } catch let failure as LumioFailure {
        precondition(failure.code == "invalid_argument")
      }
    }
    try testAudioAndHeaders()
    try testPlaylistArguments()
    try testLiveSeek()
    print("PASS: defaults, full configuration, \(valid.count) valid boundaries, \(invalid.count) invalid configurations, seek arguments, playlist indices/loop policy, and live-seek targets/rejections")
  }

  static func testViewTypeAndTimeline() throws {
    let defaultType = try LumioViewType.parse([:])
    let texture = try LumioViewType.parse(["viewType": "texture"])
    let platform = try LumioViewType.parse(["viewType": "platformView"])
    precondition(defaultType == .texture && texture == .texture && platform == .platformView)
    for raw: Any in ["unknown", "Texture", true, 1, NSNull()] {
      do { _ = try LumioViewType.parse(["viewType": raw]); fatalError("Accepted invalid viewType") }
      catch let failure as LumioFailure { precondition(failure.code == "invalid_argument") }
    }
    precondition(lumioMilliseconds(.invalid) == 0)
    precondition(lumioMilliseconds(.indefinite) == 0)
    precondition(lumioMilliseconds(.positiveInfinity) == 0)
    precondition(lumioMilliseconds(CMTime(value: -1, timescale: 1)) == 0)
    precondition(lumioMilliseconds(CMTime(value: 12345, timescale: 1000)) == 12345)
    let ranges = lumioBufferedRanges([
      CMTimeRange(start: CMTime(value: 12, timescale: 1), duration: CMTime(value: 3, timescale: 1)),
      CMTimeRange(start: CMTime(value: 20, timescale: 1), duration: CMTime(value: 2, timescale: 1)),
      .invalid, .zero,
      CMTimeRange(start: .indefinite, duration: CMTime(value: 1, timescale: 1)),
      CMTimeRange(start: CMTime(value: -2, timescale: 1), duration: CMTime(value: 1, timescale: 1)),
      CMTimeRange(start: .zero, duration: .positiveInfinity)
    ])
    precondition(ranges == [["startMs": 12000, "endMs": 15000], ["startMs": 20000, "endMs": 22000]])
    precondition(lumioBufferedRanges([]).isEmpty)
    print("PASS: viewType defaults/rejections, nonnegative position, valid/disconnected buffered ranges")
  }

  static func testAudioAndHeaders() throws {
    let defaults = try LumioConfiguration([:])
    precondition(defaults.audioPolicy == .preserveHost && !defaults.allowBackgroundPlayback)
    for policy in LumioAudioPolicy.allCases {
      for background in [false, true] {
        let config = try LumioConfiguration(["audioPolicy": policy.rawValue, "allowBackgroundPlayback": background])
        precondition(config.audioPolicy == policy && config.allowBackgroundPlayback == background)
      }
    }
    for map: [String: Any] in [
      ["audioPolicy": "unknown"], ["audioPolicy": "Exclusive"], ["audioPolicy": true],
      ["audioPolicy": NSNull()], ["allowBackgroundPlayback": 1],
      ["allowBackgroundPlayback": "true"], ["allowBackgroundPlayback": NSNull()]
    ] {
      do { _ = try LumioConfiguration(map); fatalError("Accepted invalid audio setting") }
      catch let failure as LumioFailure { precondition(failure.code == "invalid_argument") }
    }
    let headers = ["Authorization": "Bearer PRIVATE_HEADER_VALUE", "X-Custom": "valid\tvalue"]
    let parsed = try lumioHTTPHeaders(["type": "network", "headers": headers])
    precondition(parsed == headers)
    let source = LumioAssetSource(url: URL(string: "https://example.test/video.m3u8")!, headers: parsed)
    precondition(source.assetOptions?["AVURLAssetHTTPHeaderFieldsKey"] as? [String: String] == headers)
    precondition(LumioAssetSource(url: source.url).assetOptions == nil)
    for raw: Any in [
      ["Bad Name": "PRIVATE_HEADER_VALUE"], ["": "value"],
      ["X-Test": "PRIVATE_HEADER_VALUE\r\nInjected: true"], ["X-Test": "value\0"],
      ["X-Test": "one", "x-test": "two"], ["X-Test": 1], "PRIVATE_HEADER_VALUE"
    ] {
      do { _ = try lumioHTTPHeaders(["type": "network", "headers": raw]); fatalError("Accepted invalid headers") }
      catch let failure as LumioFailure {
        precondition(failure.code == "invalid_argument" && !failure.message.contains("PRIVATE_HEADER_VALUE"))
        precondition(failure.details == nil)
      }
    }
    for type in ["file", "asset"] {
      do { _ = try lumioHTTPHeaders(["type": type, "headers": headers]); fatalError("Accepted local headers") }
      catch let failure as LumioFailure { precondition(failure.code == "invalid_argument") }
    }
    print("PASS: audio policies/background defaults and validation, safe HTTP headers and AVURLAsset options")
  }

  static func testPlaylistArguments() throws {
    let first = try lumioPlaylistIndex(["index": 0], length: 1)
    let last = try lumioPlaylistIndex(["index": 2], length: 3)
    precondition(first == 0 && last == 2)
    for value: Any in [true, -1, 3, 0.5, Double.nan, Double.infinity, "0", NSNull()] {
      do {
        _ = try lumioPlaylistIndex(["index": value], length: 3)
        fatalError("Accepted invalid playlist index")
      } catch let failure as LumioFailure {
        precondition(failure.code == "invalid_argument")
      }
    }
    for (map, length): ([String: Any], Int) in [([:], 3), (["index": 0], 0)] {
      do {
        _ = try lumioPlaylistIndex(map, length: length)
        fatalError("Accepted missing index or empty playlist")
      } catch let failure as LumioFailure {
        precondition(failure.code == "invalid_argument")
      }
    }
    // Item repeat and playlist wrapping can coexist; native playback gives item repeat priority.
    let both = try LumioConfiguration(["looping": true, "loopPlaylist": true])
    precondition(both.looping && both.loopPlaylist)
  }

  static func testLiveSeek() throws {
    func time(_ seconds: Double) -> CMTime { CMTime(seconds: seconds, preferredTimescale: 1000) }
    func range(_ start: Double, _ duration: Double) -> CMTimeRange {
      CMTimeRange(start: time(start), duration: time(duration))
    }
    func expectTarget(_ duration: CMTime, _ ranges: [CMTimeRange], _ hint: Bool, _ seconds: Double) throws {
      let target = try lumioLiveSeekTarget(duration: duration, ranges: ranges, liveHint: hint)
      precondition(CMTimeCompare(target, time(seconds)) == 0)
    }
    var timeline = LumioLiveTimeline()
    precondition(timeline.observe(duration: .indefinite, ranges: []))
    timeline = LumioLiveTimeline()
    precondition(!timeline.observe(duration: time(130), ranges: [range(100, 30)]))
    precondition(!timeline.observe(duration: time(130), ranges: [range(100, 30)]))
    precondition(timeline.observe(duration: time(135), ranges: [range(105, 30)]))
    timeline = LumioLiveTimeline()
    precondition(!timeline.observe(duration: time(30), ranges: [range(100, 30)]))
    precondition(timeline.observe(duration: time(30), ranges: [range(105, 30)]))
    timeline = LumioLiveTimeline()
    precondition(!timeline.observe(duration: time(30), ranges: [range(0, 30)]))
    precondition(!timeline.observe(duration: time(130), ranges: [range(10, 30)]))
    precondition(!timeline.observe(duration: .invalid, ranges: [range(100, 30)]))
    precondition(!timeline.observe(duration: time(30), ranges: [.invalid]))
    precondition(!timeline.observe(duration: time(30), ranges: [range(100, 0)]))
    precondition(!timeline.observe(duration: time(30), ranges: []))
    // Growing buffered/seekable VOD with a fixed start is not a sliding live window.
    precondition(!timeline.observe(duration: time(130), ranges: [range(100, 30)]))
    precondition(!timeline.observe(duration: time(135), ranges: [range(100, 35)]))
    try expectTarget(.indefinite, [range(100, 30)], false, 129.5)
    try expectTarget(.indefinite, [range(0, 10), range(200, 30)], false, 229.5)
    try expectTarget(.indefinite, [range(100, 0.2)], false, 100)
    try expectTarget(.indefinite, [range(0, 30)], false, 29.5)
    try expectTarget(time(30), [range(100, 30)], true, 129.5)
    try expectTarget(time(130), [range(100, 30)], true, 129.5)

    let rejected: [(CMTime, [CMTimeRange], Bool)] = [
      (.indefinite, [], true), (.indefinite, [.invalid], true),
      (.indefinite, [range(100, 0)], true),
      (.indefinite, [CMTimeRange(start: .zero, duration: .indefinite)], true),
      (time(130), [range(100, 30)], false),
      (time(30), [range(0, 30)], false), (time(30), [range(0, 30)], true),
      (.invalid, [range(100, 30)], true)
    ]
    for (duration, ranges, hint) in rejected {
      do {
        _ = try lumioLiveSeekTarget(duration: duration, ranges: ranges, liveHint: hint)
        fatalError("Accepted unsupported live seek")
      } catch let failure as LumioFailure {
        precondition(failure.code == "unsupported_live_seek")
      }
    }
  }
}
