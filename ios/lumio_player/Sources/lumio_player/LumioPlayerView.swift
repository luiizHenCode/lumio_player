import AVFoundation
import Flutter
import UIKit

final class LumioPlayerViewFactory: NSObject, FlutterPlatformViewFactory {
  private let lookup: (Int64) -> LumioNativePlayer?

  init(lookup: @escaping (Int64) -> LumioNativePlayer?) { self.lookup = lookup }

  func createArgsCodec() -> FlutterMessageCodec & NSObjectProtocol {
    FlutterStandardMessageCodec.sharedInstance()
  }

  func create(withFrame frame: CGRect, viewIdentifier viewId: Int64,
              arguments args: Any?) -> FlutterPlatformView {
    let map = args as? [String: Any] ?? [:]
    let id = map["id"] as? NSNumber
    let valid = id.map {
      CFGetTypeID($0) != CFBooleanGetTypeID() && $0.doubleValue.isFinite &&
        $0.doubleValue >= 1 && $0.doubleValue <= Double(Int64.max / 2) &&
        $0.doubleValue.rounded() == $0.doubleValue
    } ?? false
    // FlutterPlatformViewFactory cannot return a method error. Invalid/disposed
    // ids produce an inert view, never another player or a texture fallback.
    return LumioPlatformView(frame: frame, player: valid ? lookup(id!.int64Value) : nil)
  }
}

final class LumioPlatformView: NSObject, FlutterPlatformView {
  private let surface: LumioPlayerSurface

  init(frame: CGRect, player: LumioNativePlayer?) {
    surface = LumioPlayerSurface(frame: frame, player: player)
    super.init()
  }

  func view() -> UIView { surface }
}

final class LumioPlayerSurface: UIView {
  override class var layerClass: AnyClass { AVPlayerLayer.self }
  var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
  private weak var owner: LumioNativePlayer?

  init(frame: CGRect, player: LumioNativePlayer?) {
    owner = player
    super.init(frame: frame)
    backgroundColor = .black
    playerLayer.videoGravity = .resizeAspect
    player?.attachLayer(playerLayer)
  }

  required init?(coder: NSCoder) { fatalError("init(coder:) is unavailable") }

  override func didMoveToWindow() {
    super.didMoveToWindow()
    owner?.setLayerVisible(playerLayer, visible: window != nil)
  }

  deinit { owner?.detachLayer(playerLayer) }
}
