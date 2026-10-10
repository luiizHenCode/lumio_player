import AVFoundation
import Flutter
import XCTest

private final class AudioTextureRegistry: NSObject, FlutterTextureRegistry {
  func register(_ texture: FlutterTexture) -> Int64 { 1 }
  func textureFrameAvailable(_ textureId: Int64) {}
  func unregisterTexture(_ textureId: Int64) {}
}

// Include with production sources in an iOS XCTest host linked to Flutter.
final class AudioPolicyTests: XCTestCase {
  func testPreserveHostAndDisposeLeaveSharedSessionUntouched() throws {
    let session = AVAudioSession.sharedInstance()
    let category = session.category
    let mode = session.mode
    let options = session.categoryOptions
    defer { try? session.setCategory(category, mode: mode, options: options) }
    try session.setCategory(.ambient, mode: .default, options: [.mixWithOthers])
    try lumioConfigureAudioSession(.preserveHost)
    let player = LumioNativePlayer(id: 1, registry: AudioTextureRegistry()) { _ in }
    player.dispose()
    XCTAssertEqual(session.category, .ambient)
    XCTAssertEqual(session.mode, .default)
    XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
  }

  func testExplicitPoliciesSelectPlaybackMixing() throws {
    let session = AVAudioSession.sharedInstance()
    let category = session.category
    let mode = session.mode
    let options = session.categoryOptions
    defer { try? session.setCategory(category, mode: mode, options: options) }
    try lumioConfigureAudioSession(.mixWithOthers)
    XCTAssertEqual(session.category, .playback)
    XCTAssertTrue(session.categoryOptions.contains(.mixWithOthers))
    try lumioConfigureAudioSession(.exclusive)
    XCTAssertEqual(session.category, .playback)
    XCTAssertFalse(session.categoryOptions.contains(.mixWithOthers))
  }
}
