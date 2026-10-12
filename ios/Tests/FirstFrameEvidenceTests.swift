import Foundation

// Host-runnable tests of the exact state reducer used by the native player.
@main
struct FirstFrameEvidenceTests {
  static func main() {
    let item = NSObject(), otherItem = NSObject(), layer = NSObject(), otherLayer = NSObject()
    var state = LumioFirstFrameEvidence()
    func expectEmpty(_ state: LumioFirstFrameEvidence) {
      precondition(state.snapshot["hasRenderedFirstFrame"] as? Bool == false)
      precondition(state.snapshot["firstFrameSupported"] as? Bool == true)
      precondition(state.snapshot["firstFrameEvidence"] == nil)
    }
    expectEmpty(state)
    precondition(!state.pixelBuffer(state.token)) // No item, no frame.
    state.reset(generation: 1, item: ObjectIdentifier(item))
    let first = state.token
    precondition(state.pixelBuffer(first))
    precondition(state.snapshot["hasRenderedFirstFrame"] as? Bool == true)
    precondition(state.snapshot["firstFrameEvidence"] as? String == "pixelBuffer")
    precondition(!state.pixelBuffer(first)) // No per-frame state flood.

    state.reset(generation: 2, item: ObjectIdentifier(item)) // Source replaced, same identity.
    expectEmpty(state)
    precondition(!state.pixelBuffer(first))
    let replacement = state.token
    state.reset(generation: 2, item: ObjectIdentifier(item)) // Explicit same-item selection.
    expectEmpty(state)
    precondition(!state.pixelBuffer(replacement))
    precondition(state.pixelBuffer(state.token))
    let selected = state.token
    state.reset(generation: 3, item: ObjectIdentifier(otherItem)) // Native queue transition.
    expectEmpty(state)
    precondition(!state.pixelBuffer(selected))

    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(layer), layerReady: true)
    let attached = state.token
    precondition(!state.pixelBuffer(attached))
    precondition(!state.layerReady(true, token: attached)) // Old retained image on attach.
    expectEmpty(state)
    precondition(!state.layerReady(false, token: attached))
    precondition(state.layerReady(true, token: attached))
    precondition(state.snapshot["firstFrameEvidence"] as? String == "layerReady")
    precondition(!state.layerReady(true, token: attached))
    precondition(!state.layerReady(false, token: attached))
    precondition(!state.layerReady(true, token: attached)) // Latched until reset.

    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(layer), layerReady: true)
    let reattached = state.token
    expectEmpty(state)
    precondition(!state.layerReady(false, token: attached)) // Late old false must not arm new layer.
    precondition(!state.layerReady(true, token: attached))
    precondition(!state.layerReady(true, token: reattached))
    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(otherLayer), layerReady: false)
    precondition(!state.layerReady(true, token: reattached))
    precondition(state.layerReady(true, token: state.token))
    // Observer is installed while disconnected. Readiness during the new bind
    // is accepted immediately; no future false notification is required.
    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(otherLayer), layerReady: false)
    let fresh = state.token
    state.qualifyLayerBinding(fresh)
    precondition(state.layerReady(true, token: fresh))
    precondition(state.snapshot["firstFrameEvidence"] as? String == "layerReady")

    // A synchronous image whose KVO arrives inside the setter can also be
    // recovered by the post-bind sample when the disconnected baseline was false.
    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(otherLayer), layerReady: false)
    state.qualifyLayerBinding(state.token)
    precondition(state.layerReady(true, token: state.token, bindingSnapshot: true))

    // Reused layer never reports false: old true samples remain rejected, but
    // a NEW readiness notification after the qualified nil/rebind can complete.
    state.reset(generation: 3, item: ObjectIdentifier(otherItem), layer: ObjectIdentifier(otherLayer), layerReady: true)
    let rebound = state.token
    state.qualifyLayerBinding(rebound)
    precondition(!state.layerReady(true, token: rebound, bindingSnapshot: true))
    precondition(!state.layerReady(false, token: fresh))
    precondition(!state.layerReady(true, token: fresh))
    expectEmpty(state)
    precondition(state.layerReady(true, token: rebound))
    precondition(!state.layerReady(true, token: rebound))
    state.reset(generation: 4, item: nil)
    expectEmpty(state)
    precondition(!state.layerReady(true, token: reattached))
    print("PASS: first-frame snapshot, source/item/same-selection resets, stale buffers/layer callbacks, qualified immediate readiness, nil/rebind without false, retained-image rejection and one-shot evidence")
  }
}
