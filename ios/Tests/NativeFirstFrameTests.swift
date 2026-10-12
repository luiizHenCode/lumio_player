import AVFoundation
import Flutter
import XCTest

private final class FirstFrameRegistry: NSObject, FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 42 }
  func unregisterTexture(_ textureId: Int64) {}
  func textureFrameAvailable(_ textureId: Int64) {}
}

// Synthetic KVO tests ordering/identity, not AVFoundation image decoding.
private final class EvidenceLayer: AVPlayerLayer {
  private var ready = false
  var imageOnBind = true
  var clearOnDisconnect = true
  private(set) var bindings = 0
  override var isReadyForDisplay: Bool { ready }
  override var player: AVPlayer? {
    get { super.player }
    set {
      super.player = newValue
      if newValue == nil {
        // Deliberately no false KVO: readiness is sampled before binding.
        if clearOnDisconnect { ready = false }
      } else {
        bindings += 1
        if imageOnBind { observeImage(true) } // Immediate, inside the setter.
      }
    }
  }
  func observeImage(_ value: Bool) {
    willChangeValue(forKey: "readyForDisplay")
    ready = value
    didChangeValue(forKey: "readyForDisplay")
  }
}

final class NativeFirstFrameTests: XCTestCase {
  func testImmediateBindReusedLayerAndSelectionEpoch() throws {
    XCTAssertTrue(Thread.isMainThread)
    var latest: [String: Any] = [:]
    var states: [[String: Any]] = []
    let player = LumioNativePlayer(id: 1, registry: FirstFrameRegistry(), viewType: .platformView) { event in
      guard event["type"] as? String == "state" else { return }
      latest = event
      states.append(event)
    }
    defer { player.dispose() }
    let sources = [URL(fileURLWithPath: "/first-frame-a.mov"), URL(fileURLWithPath: "/first-frame-b.mov")]
    player.emitState()
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 0)
    player.openPlaylist(urls: sources, index: 0, configuration: try LumioConfiguration([:]))
    let old = EvidenceLayer()
    player.attachLayer(old) // New layer becomes ready immediately on first bind.
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")
    XCTAssertEqual(old.bindings, 1)
    let count = states.count
    old.observeImage(true)
    XCTAssertEqual(states.count, count) // Subsequent frames do not flood state.

    old.clearOnDisconnect = false // Retains true, never emits a false notification.
    states.removeAll()
    player.selectPlaylistItem(index: 0, selectionEpoch: 7)
    XCTAssertTrue(states.allSatisfy { $0["selectionEpoch"] as? Int64 == 7 })
    XCTAssertEqual(latest["playlistIndex"] as? Int, 0)
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")
    XCTAssertEqual(old.bindings, 2) // A real nil/rebind, even for same selection.
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 7)

    player.selectPlaylistItem(index: 0, selectionEpoch: 8)
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 8)
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")
    (old.player as! AVQueuePlayer).advanceToNextItem()
    player.emitState()
    XCTAssertEqual(latest["playlistIndex"] as? Int, 1)
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 8) // Native advance preserves epoch.
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")

    let new = EvidenceLayer()
    player.attachLayer(new)
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")
    let replacementCount = states.count
    old.observeImage(false)
    old.observeImage(true)
    player.detachLayer(old)
    XCTAssertEqual(states.count, replacementCount)
    player.setLayerVisible(new, visible: false)
    XCTAssertEqual(latest["hasRenderedFirstFrame"] as? Bool, false)
    XCTAssertNil(latest["firstFrameEvidence"])
    player.setLayerVisible(new, visible: true)
    XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady") // No false event required.
    player.detachLayer(new)
    XCTAssertEqual(latest["hasRenderedFirstFrame"] as? Bool, false)
    new.observeImage(true)
    XCTAssertNil(latest["firstFrameEvidence"])

    player.open(url: sources[0], configuration: try LumioConfiguration([:]))
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 0)
    player.selectPlaylistItem(index: 0, selectionEpoch: 9)
    player.openPlaylist(urls: sources, index: 0, configuration: try LumioConfiguration([:]))
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 0)
    player.selectPlaylistItem(index: 0) // Optional argument defaults to zero.
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 0)
    player.dispose()
    let disposedCount = states.count
    new.observeImage(false)
    new.observeImage(true)
    XCTAssertEqual(states.count, disposedCount)
  }

  func testRetainedTrueAndQueuedOldCallbackCannotCompleteNewSelection() throws {
    var latest: [String: Any] = [:]
    let player = LumioNativePlayer(id: 1, registry: FirstFrameRegistry(), viewType: .platformView) { event in
      if event["type"] as? String == "state" { latest = event }
    }
    defer { player.dispose() }
    player.open(url: URL(fileURLWithPath: "/first-frame.mov"), configuration: try LumioConfiguration([:]))
    let layer = EvidenceLayer()
    player.attachLayer(layer)
    layer.clearOnDisconnect = false
    layer.imageOnBind = false
    // Queue the old observation's main-thread handoff before resetting its token.
    DispatchQueue.global().sync { layer.observeImage(true) }
    player.selectPlaylistItem(index: 0, selectionEpoch: 42)
    XCTAssertEqual(latest["selectionEpoch"] as? Int64, 42)
    XCTAssertEqual(latest["hasRenderedFirstFrame"] as? Bool, false)
    XCTAssertNil(latest["firstFrameEvidence"]) // Retained true sample is unqualified.
    let drained = expectation(description: "Old observation handoff discarded")
    DispatchQueue.main.async {
      XCTAssertEqual(latest["hasRenderedFirstFrame"] as? Bool, false)
      XCTAssertEqual(latest["selectionEpoch"] as? Int64, 42)
      layer.observeImage(true) // New bind's notification; no intervening false.
      XCTAssertEqual(latest["firstFrameEvidence"] as? String, "layerReady")
      drained.fulfill()
    }
    wait(for: [drained], timeout: 5)
  }
}
