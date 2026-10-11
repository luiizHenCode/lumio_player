import Foundation

private final class CyclicError: NSError, @unchecked Sendable {
  var next: NSError?
  override var userInfo: [String: Any] { next.map { [NSUnderlyingErrorKey: $0] } ?? [:] }
  init() { super.init(domain: NSURLErrorDomain, code: -1005, userInfo: nil) }
  required init?(coder: NSCoder) { fatalError("Not used") }
}

@main
struct LiveErrorTests {
  static func main() {
    func classify(_ domain: String, _ code: Int, _ info: [String: Any] = [:]) -> LumioNativeErrorClassification {
      lumioClassifyNativeError(NSError(domain: domain, code: code, userInfo: info))
    }
    for code in [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020] {
      let result = classify(NSURLErrorDomain, code)
      precondition(result.transient && result.chainComplete)
      for live in [false, true] {
        for ready in [false, true] {
          for detected in [false, true] {
            let allowed = live && ready && detected
            precondition(result.canRecover(liveConfigured: live, wasReady: ready, liveDetected: detected) == allowed)
            for phase in ["open_failed", "playback_failed"] {
              let disposition = result.disposition(phase: phase, liveConfigured: live, wasReady: ready, liveDetected: detected)
              precondition(disposition.recoverable == allowed)
              precondition(disposition.code == (allowed ? "ios_live_network_interruption" : "ios_native_terminal_error"))
              precondition(disposition.nativeErrorPhase == phase)
              precondition(disposition.code != phase)
            }
          }
        }
      }
    }
    precondition(classify("AVFoundationErrorDomain", -11819).transient)
    for (domain, codes) in [
      (NSURLErrorDomain, [-999, -1011, -1012, -1013, -1015, -1016, -1022, -1200, -1202, 401, 403, 404, 0]),
      ("AVFoundationErrorDomain", [-11800, -11828, -11829, -11833, -11835, -11850, -11855, 404]),
      ("HTTPErrorDomain", [401, 403, 404]),
      ("unknown", [-1001, -11819])
    ] {
      for code in codes { precondition(!classify(domain, code).transient) }
    }
    precondition(!lumioClassifyNativeError(nil).transient)
    let timeout = NSError(domain: NSURLErrorDomain, code: -1001)
    let nested = classify("AVFoundationErrorDomain", -11819, [NSUnderlyingErrorKey: timeout])
    precondition(nested.transient && nested.chain.count == 2)
    let wrappedTimeout = classify("AVFoundationErrorDomain", -11800, [NSUnderlyingErrorKey: timeout])
    precondition(wrappedTimeout.transient && wrappedTimeout.chain.count == 2)
    precondition(wrappedTimeout.disposition(phase: "playback_failed", liveConfigured: true,
      wasReady: true, liveDetected: true).code == "ios_live_network_interruption")
    for (domain, code) in [(NSURLErrorDomain, -1013), ("AVFoundationErrorDomain", -11833),
                           ("AVFoundationErrorDomain", -11850), ("unknown", -1001)] {
      let inner = NSError(domain: domain, code: code)
      let wrapped = classify("AVFoundationErrorDomain", -11800, [NSUnderlyingErrorKey: inner])
      let disposition = wrapped.disposition(phase: "open_failed", liveConfigured: true,
        wasReady: true, liveDetected: true)
      precondition(!wrapped.transient && !disposition.recoverable)
      precondition(disposition.code == "ios_native_terminal_error" && disposition.nativeErrorPhase == "open_failed")
    }
    for outerCode in [-11833, -11850, -11835] {
      precondition(!classify("AVFoundationErrorDomain", outerCode, [NSUnderlyingErrorKey: timeout]).transient)
    }
    let unknownWrapper = classify("unknown", -11800, [NSUnderlyingErrorKey: timeout])
    precondition(!unknownWrapper.transient)
    precondition(unknownWrapper.disposition(phase: "playback_failed", liveConfigured: true,
      wasReady: true, liveDetected: true).code == "ios_native_terminal_error")
    precondition(!classify("AVFoundationErrorDomain", -11800, [NSUnderlyingErrorKey:
      NSError(domain: "AVFoundationErrorDomain", code: -11800)]).transient)
    precondition(classify("AVFoundationErrorDomain", -11800, [NSUnderlyingErrorKey:
      NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: timeout])]).transient)
    let forbidden = NSError(domain: "HTTPErrorDomain", code: 404)
    precondition(!classify(NSURLErrorDomain, -1005, [NSUnderlyingErrorKey: forbidden]).transient)
    let unknown = NSError(domain: "https://user:PRIVATE@host.test", code: -1001)
    let sanitized = classify(NSURLErrorDomain, -1005, [NSUnderlyingErrorKey: unknown])
    precondition(!sanitized.transient && sanitized.chain[1]["domain"] as? String == "unknown")

    for status in [401, 403, 404] {
      precondition(!lumioClassifyNativeError(timeout, currentLogStatusCodes: [status]).transient)
      let wrapper = NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: timeout])
      precondition(!lumioClassifyNativeError(wrapper, currentLogStatusCodes: [status]).transient)
      precondition(!classify("AVFoundationErrorDomain", -11800,
        [NSUnderlyingErrorKey: timeout, "HTTPStatusCode": status]).transient)
      let httpInner = NSError(domain: NSURLErrorDomain, code: -1001, userInfo: ["HTTPStatusCode": status])
      precondition(!classify("AVFoundationErrorDomain", -11800, [NSUnderlyingErrorKey: httpInner]).transient)
      precondition(!classify(NSURLErrorDomain, -1001, ["HTTPStatusCode": status]).transient)
      let response = HTTPURLResponse(url: URL(string: "https://host.test/segment.ts?token=PRIVATE")!,
                                     statusCode: status, httpVersion: nil, headerFields: nil)!
      precondition(!classify(NSURLErrorDomain, -1001, ["response": response]).transient)
    }
    precondition(lumioClassifyNativeError(timeout, currentLogStatusCodes: [-1001, 500]).transient)
    let textOnly = classify(NSURLErrorDomain, -1001, [
      NSLocalizedDescriptionKey: "404 segment.ts https://user:PRIVATE@host.test/key",
      "comment": "HTTP 401", "serverAddress": "PRIVATE", "HTTPStatusCode": "404",
      NSURLErrorFailingURLErrorKey: URL(string: "https://host.test/404.ts")!
    ])
    precondition(textOnly.transient)
    let data = try! JSONSerialization.data(withJSONObject: textOnly.chain)
    let json = String(data: data, encoding: .utf8)!
    precondition(!json.contains("PRIVATE") && !json.contains("https") && !json.contains("404"))

    var exactLimit: NSError = timeout
    for _ in 0..<15 { exactLimit = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSUnderlyingErrorKey: exactLimit]) }
    precondition(lumioClassifyNativeError(exactLimit).transient)
    var deep: NSError = timeout
    for _ in 0..<16 { deep = NSError(domain: NSURLErrorDomain, code: -1005, userInfo: [NSUnderlyingErrorKey: deep]) }
    let bounded = lumioClassifyNativeError(deep)
    precondition(!bounded.transient && !bounded.chainComplete && bounded.chain.count == 16)
    let first = CyclicError()
    let second = CyclicError()
    first.next = second
    second.next = first
    let cycle = lumioClassifyNativeError(first)
    precondition(!cycle.transient && !cycle.chainComplete && cycle.chain.count == 2)
    first.next = nil
    second.next = nil

    var history = LumioLiveErrorHistory()
    precondition(!history.wasReady && !history.liveDetected)
    history.observeReady(live: true, logCount: 2)
    precondition(history.wasReady && history.liveDetected)
    let historicalOnly = lumioClassifyNativeError(
      NSError(domain: "AVFoundationErrorDomain", code: -11800, userInfo: [NSUnderlyingErrorKey: timeout]),
      currentLogStatusCodes: history.currentStatusCodes([404, 401]))
    precondition(historicalOnly.transient)
    let historicalDisposition = historicalOnly.disposition(phase: "playback_failed", liveConfigured: true,
      wasReady: history.wasReady, liveDetected: history.liveDetected)
    precondition(historicalDisposition.code == "ios_live_network_interruption" && historicalDisposition.recoverable)
    precondition(!lumioClassifyNativeError(timeout, currentLogStatusCodes: history.currentStatusCodes([404, 401, 403])).transient)
    history.observeReady(live: false, logCount: 3)
    // A delayed ready KVO snapshot must not move the healthy watermark backwards.
    history.observeReady(live: false, logCount: 1)
    history.observeReady(live: false)
    precondition(history.liveDetected)
    precondition(history.currentStatusCodes([404, 401, 403, -1005]) == [-1005])
    history.reset()
    precondition(!history.wasReady && !history.liveDetected)
    precondition(history.currentStatusCodes([404]) == [404])
    print("PASS: transient allowlist, AVFoundation -11800 wrappers, terminal codec/auth/HTTP evidence, explicit event codes/phases and recovery gates, safe diagnostics, bounded/cyclic chains, historical/current logs and item reset")
  }
}
