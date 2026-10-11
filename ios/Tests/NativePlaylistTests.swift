import AVFoundation
import Flutter
import XCTest

private final class PlaylistTextureRegistry: NSObject, FlutterTextureRegistry {
  var registrations = 0
  var removals = 0
  func register(_ texture: FlutterTexture) -> Int64 { registrations += 1; return 42 }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) { removals += 1 }
}

// Include with the production Swift sources in an iOS XCTest host linked to Flutter.
// Real local audio exercises AVQueuePlayer transitions without network credentials.
final class NativePlaylistTests: XCTestCase {
  private var files: [URL] = []
  private var players: [LumioNativePlayer] = []

  override func tearDown() {
    players.forEach { $0.dispose() }
    files.forEach { try? FileManager.default.removeItem(at: $0) }
    players.removeAll()
    files.removeAll()
    super.tearDown()
  }

  private func audio() throws -> URL {
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".wav")
    let format = AVAudioFormat(standardFormatWithSampleRate: 8000, channels: 1)!
    let file = try AVAudioFile(forWriting: url, settings: format.settings)
    let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 8000)!
    buffer.frameLength = 8000
    buffer.floatChannelData![0].initialize(repeating: 0, count: 8000)
    try file.write(from: buffer)
    files.append(url)
    return url
  }

  private func makePlayer(_ registry: PlaylistTextureRegistry = PlaylistTextureRegistry(),
                          emit: @escaping ([String: Any]) -> Void) -> LumioNativePlayer {
    XCTAssertTrue(Thread.isMainThread)
    let player = LumioNativePlayer(id: 1, registry: registry, emit: emit)
    players.append(player)
    return player
  }

  func testNativeAdvanceAndFinalCompletion() throws {
    let done = expectation(description: "Both queued items play and final item completes")
    var indices = Set<Int>()
    var finished = false
    let registry = PlaylistTextureRegistry()
    let player = makePlayer(registry) { event in
      guard event["type"] as? String == "state" else { return }
      XCTAssertEqual(event["playlistLength"] as? Int, 2)
      if event["initialized"] as? Bool == true { indices.insert(event["playlistIndex"] as! Int) }
      if event["completed"] as? Bool == true && !finished {
        finished = true
        XCTAssertEqual(event["playlistIndex"] as? Int, 1)
        XCTAssertGreaterThan(event["positionMs"] as? Int64 ?? 0, 0)
        done.fulfill()
      }
    }
    player.openPlaylist(urls: [try audio(), try audio()], index: 0,
                        configuration: try LumioConfiguration(["autoPlay": true]))
    wait(for: [done], timeout: 15)
    XCTAssertEqual(indices, [0, 1])
    XCTAssertEqual(registry.registrations, 1)
    player.dispose()
    player.dispose()
    XCTAssertEqual(registry.removals, 1)
  }

  func testPlaylistWrapsNatively() throws {
    let wrapped = expectation(description: "Queue wraps from last item to first")
    var sawLast = false
    var fulfilled = false
    let player = makePlayer { event in
      guard event["type"] as? String == "state" else { return }
      XCTAssertFalse(event["completed"] as? Bool ?? false)
      let index = event["playlistIndex"] as? Int
      if index == 1 { sawLast = true }
      if sawLast && index == 0 && !fulfilled { fulfilled = true; wrapped.fulfill() }
    }
    player.openPlaylist(urls: [try audio(), try audio()], index: 0,
                        configuration: try LumioConfiguration(["autoPlay": true, "loopPlaylist": true]))
    wait(for: [wrapped], timeout: 15)
    player.pause()
  }

  func testItemLoopTakesPriorityAndSelectionPauses() throws {
    let repeated = expectation(description: "Selected item repeats without advancing")
    var sawProgress = false
    var fulfilled = false
    var selecting = false
    var latest: [String: Any] = [:]
    let registry = PlaylistTextureRegistry()
    let player = makePlayer(registry) { event in
      guard event["type"] as? String == "state" else { return }
      latest = event
      guard !selecting else { return }
      XCTAssertEqual(event["playlistIndex"] as? Int, 0)
      let position = event["positionMs"] as? Int64 ?? -1
      if position > 100 { sawProgress = true }
      if sawProgress && position == 0 && !fulfilled {
        fulfilled = true
        repeated.fulfill()
      }
    }
    player.openPlaylist(urls: [try audio(), try audio()], index: 0,
                        configuration: try LumioConfiguration([
                          "autoPlay": true, "looping": true, "loopPlaylist": true
                        ]))
    wait(for: [repeated], timeout: 15)
    selecting = true
    player.selectPlaylistItem(index: 1)
    XCTAssertEqual(latest["playlistIndex"] as? Int, 1)
    XCTAssertFalse(latest["playing"] as? Bool ?? true)
    XCTAssertFalse(latest["completed"] as? Bool ?? true)
    XCTAssertEqual(player.textureID, 42)
    XCTAssertEqual(registry.registrations, 1)
    player.play() // Parent next/previous explicitly restores playback intent.
    player.dispose()
  }

  func testFailedItemDoesNotAdvanceOrExposeSourceText() throws {
    let failed = expectation(description: "Current item fails without leaking its URL")
    let marker = "PRIVATE_SIGNED_SOURCE_TOKEN"
    let url = FileManager.default.temporaryDirectory.appendingPathComponent(marker + ".wav")
    try Data("not a playable media file".utf8).write(to: url)
    files.append(url)
    var fulfilled = false
    let player = makePlayer { event in
      guard event["type"] as? String == "error", !fulfilled else { return }
      fulfilled = true
      let payload = String(data: try! JSONSerialization.data(withJSONObject: event), encoding: .utf8)!
      XCTAssertFalse(payload.contains(marker))
      XCTAssertEqual(event["recoverable"] as? Bool, false)
      XCTAssertEqual(event["code"] as? String, "ios_native_terminal_error")
      let details = event["details"] as? [String: Any]
      XCTAssertEqual(details?["nativeErrorPhase"] as? String, "open_failed")
      failed.fulfill()
    }
    player.openPlaylist(urls: [url, try audio()], index: 0,
                        configuration: try LumioConfiguration(["autoPlay": true]))
    wait(for: [failed], timeout: 15)
    let diagnostics = player.diagnostics()
    XCTAssertEqual(diagnostics["playlistIndex"] as? Int, 0)
    let payload = String(data: try JSONSerialization.data(withJSONObject: diagnostics), encoding: .utf8)!
    XCTAssertFalse(payload.contains(marker))
  }

  func testReplacementAndDisposalSuppressStaleCallbacks() throws {
    var events = 0
    let player = makePlayer { _ in events += 1 }
    let urls = [try audio(), try audio()]
    player.openPlaylist(urls: urls, index: 0, configuration: try LumioConfiguration(["autoPlay": true]))
    player.selectPlaylistItem(index: 1)
    player.open(url: urls[0], configuration: try LumioConfiguration([:]))
    XCTAssertEqual(player.playlistLength, 1)
    _ = player.diagnostics() // Start asynchronous metadata loading before disposal.
    player.dispose()
    player.dispose()
    XCTAssertEqual(player.playlistLength, 0)
    XCTAssertNil(player.copyPixelBuffer())
    let count = events
    let drained = expectation(description: "Main queue drains pending KVO callbacks")
    DispatchQueue.main.async { drained.fulfill() }
    wait(for: [drained], timeout: 2)
    XCTAssertEqual(events, count)
  }

  func testDisposedPlayerIsNotRetainedByObserversOrTimers() throws {
    let registry = PlaylistTextureRegistry()
    weak var released: LumioNativePlayer?
    autoreleasepool {
      let player = LumioNativePlayer(id: 2, registry: registry) { _ in }
      released = player
      player.dispose()
      player.dispose()
    }
    XCTAssertNil(released)
    XCTAssertEqual(registry.removals, 1)
  }
}
