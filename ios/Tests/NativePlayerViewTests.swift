import AVFoundation
import Flutter
import UIKit
import XCTest

private final class ViewTextureRegistry: NSObject, FlutterTextureRegistry {
  var registrations = 0
  var removals = 0
  var frames = 0
  func register(_ texture: FlutterTexture) -> Int64 { registrations += 1; return 42 }
  func unregisterTexture(_ textureId: Int64) { removals += 1 }
  func textureFrameAvailable(_ textureId: Int64) { frames += 1 }
}

// Compile with production sources in the Flutter-linked iOS XCTest host.
final class NativePlayerViewTests: XCTestCase {
  func testRemountOwnershipAndDisposal() {
    XCTAssertTrue(Thread.isMainThread)
    let registry = ViewTextureRegistry()
    let player = LumioNativePlayer(id: 1, registry: registry, viewType: .platformView) { _ in }
    defer { player.dispose() }
    XCTAssertEqual(player.getPosition(), 0)
    var old: LumioPlayerSurface? = LumioPlayerSurface(frame: .zero, player: player)
    let queue = old!.playerLayer.player
    XCTAssertTrue(queue is AVQueuePlayer)
    let new = LumioPlayerSurface(frame: .zero, player: player)
    XCTAssertNil(old!.playerLayer.player)
    XCTAssertTrue(new.playerLayer.player === queue)
    player.setLayerVisible(old!.playerLayer, visible: false)
    player.setLayerVisible(old!.playerLayer, visible: true)
    old = nil // Old deinit must not detach the fullscreen/remounted surface.
    XCTAssertTrue(new.playerLayer.player === queue)
    player.setLayerVisible(new.playerLayer, visible: false)
    XCTAssertNil(new.playerLayer.player)
    player.setLayerVisible(new.playerLayer, visible: true)
    XCTAssertTrue(new.playerLayer.player === queue)
    player.dispose()
    XCTAssertNil(new.playerLayer.player)
    player.attachLayer(new.playerLayer)
    player.setLayerVisible(new.playerLayer, visible: true)
    XCTAssertNil(new.playerLayer.player)
    XCTAssertEqual(registry.registrations, 0)
    XCTAssertEqual(registry.removals, 0)
    XCTAssertEqual(registry.frames, 0)
    XCTAssertNil(player.copyPixelBuffer())
  }

  func testViewReleaseDoesNotDisposePlayerAndStateIsPreserved() throws {
    let registry = ViewTextureRegistry()
    var state: [String: Any] = [:]
    let player = LumioNativePlayer(id: 1, registry: registry, viewType: .platformView) { state = $0 }
    defer { player.dispose() }
    weak var released: LumioPlayerSurface?
    autoreleasepool {
      let surface = LumioPlayerSurface(frame: .zero, player: player)
      released = surface
    }
    XCTAssertNil(released)
    let replacement = LumioPlayerSurface(frame: .zero, player: player)
    let queue = replacement.playerLayer.player as! AVQueuePlayer
    let urls = [URL(fileURLWithPath: "/nonexistent-first.wav"), URL(fileURLWithPath: "/nonexistent-second.wav")]
    player.openPlaylist(urls: urls, index: 0, configuration: try LumioConfiguration([:]))
    XCTAssertTrue(replacement.playerLayer.player === queue)
    XCTAssertEqual(queue.items().count, 2)
    XCTAssertTrue(queue.items().allSatisfy { $0.outputs.isEmpty })
    player.selectPlaylistItem(index: 1)
    XCTAssertTrue(replacement.playerLayer.player === queue)
    XCTAssertEqual(state["playlistIndex"] as? Int, 1)
    XCTAssertEqual(state["playlistLength"] as? Int, 2)
    XCTAssertEqual(state["bufferedRanges"] as? [[String: Int64]], [])
    XCTAssertNotNil(state["bufferedPositionMs"])
    XCTAssertEqual(registry.registrations, 0)
    XCTAssertEqual(registry.frames, 0)
  }

  func testFactoryCodecAndInvalidOrTextureIdsAreInert() {
    let registry = ViewTextureRegistry()
    let player = LumioNativePlayer(id: 1, registry: registry) { _ in }
    defer { player.dispose() }
    let factory = LumioPlayerViewFactory { $0 == 1 ? player : nil }
    XCTAssertTrue(factory.createArgsCodec() is FlutterStandardMessageCodec)
    for args: Any in [["id": 1], ["id": true], ["id": 1.5], ["id": -1], ["id": 999], [:]] {
      let view = factory.create(withFrame: .zero, viewIdentifier: 0, arguments: args).view()
      XCTAssertNil((view.layer as! AVPlayerLayer).player)
    }
    XCTAssertEqual(registry.registrations, 1)
    player.dispose()
    XCTAssertEqual(registry.removals, 1)
  }
}
