import Foundation

// Epoch also distinguishes a reattachment or explicit selection of the same item.
struct LumioFirstFrameToken: Equatable {
  let epoch: Int
  let generation: Int
  let item: ObjectIdentifier?
  let layer: ObjectIdentifier?
}

struct LumioFirstFrameEvidence {
  private(set) var token = LumioFirstFrameToken(epoch: 0, generation: 0, item: nil, layer: nil)
  private(set) var evidence: String?
  private var layerSawNotReady = false
  private var layerBindingQualified = false

  mutating func reset(generation: Int, item: ObjectIdentifier?, layer: ObjectIdentifier? = nil,
                      layerReady: Bool = true) {
    token = LumioFirstFrameToken(epoch: token.epoch + 1, generation: generation, item: item, layer: layer)
    evidence = nil
    // An already-ready layer can still contain the previous item's image.
    layerSawNotReady = !layerReady
    layerBindingQualified = false
  }

  // Only called after disconnecting and installing the observer, before the
  // exclusive current-item rebind. This qualifies new notifications, not old images.
  mutating func qualifyLayerBinding(_ observed: LumioFirstFrameToken) {
    guard observed == token, token.item != nil, token.layer != nil else { return }
    layerBindingQualified = true
  }

  mutating func pixelBuffer(_ observed: LumioFirstFrameToken) -> Bool {
    guard observed == token, token.item != nil, token.layer == nil, evidence == nil else { return false }
    evidence = "pixelBuffer"
    return true
  }

  mutating func layerReady(_ ready: Bool, token observed: LumioFirstFrameToken,
                           bindingSnapshot: Bool = false) -> Bool {
    guard observed == token, token.item != nil, token.layer != nil else { return false }
    if !ready { layerSawNotReady = true; return false }
    guard layerSawNotReady || (layerBindingQualified && !bindingSnapshot),
          evidence == nil else { return false }
    evidence = "layerReady"
    return true
  }

  var snapshot: [String: Any] {
    var result: [String: Any] = [
      "hasRenderedFirstFrame": evidence != nil,
      "firstFrameSupported": true
    ]
    if let evidence = evidence { result["firstFrameEvidence"] = evidence }
    return result
  }
}
