import Foundation

struct LumioNativeErrorDisposition {
  let code: String
  let recoverable: Bool
  let nativeErrorPhase: String
}

struct LumioNativeErrorClassification {
  let chain: [[String: Any]]
  let chainComplete: Bool
  let transient: Bool

  func canRecover(liveConfigured: Bool, wasReady: Bool, liveDetected: Bool) -> Bool {
    liveConfigured && wasReady && liveDetected && transient
  }

  func disposition(phase: String, liveConfigured: Bool, wasReady: Bool, liveDetected: Bool) -> LumioNativeErrorDisposition {
    let recoverable = canRecover(liveConfigured: liveConfigured, wasReady: wasReady, liveDetected: liveDetected)
    return LumioNativeErrorDisposition(
      code: recoverable ? "ios_live_network_interruption" : "ios_native_terminal_error",
      recoverable: recoverable, nativeErrorPhase: phase)
  }
}

// No descriptions, URLs, comments or arbitrary userInfo values are interpreted.
// Every node must be allowlisted. AVFoundation -11800 may wrap an allowed
// transient chain, but is never evidence of a network failure on its own.
func lumioClassifyNativeError(_ error: NSError?, currentLogStatusCodes: [Int] = []) -> LumioNativeErrorClassification {
  let transientURLCodes: Set<Int> = [-1001, -1003, -1004, -1005, -1006, -1009, -1018, -1019, -1020]
  let terminalHTTP: Set<Int> = [401, 403, 404]
  let safeDomains: Set<String> = [NSURLErrorDomain, "AVFoundationErrorDomain", "NSOSStatusErrorDomain", "NSPOSIXErrorDomain", NSCocoaErrorDomain, "HTTP", "HTTPErrorDomain"]
  var chain: [[String: Any]] = []
  var seen = Set<ObjectIdentifier>()
  var current = error
  var hasTransient = false
  var allowed = error != nil && !currentLogStatusCodes.contains(where: { terminalHTTP.contains($0) })
  while let node = current, chain.count < 16 {
    guard seen.insert(ObjectIdentifier(node)).inserted else { break }
    // Unknown domains can themselves contain credentials; do not echo arbitrary strings.
    chain.append(["domain": safeDomains.contains(node.domain) ? node.domain : "unknown", "code": node.code])
    let transient = (node.domain == NSURLErrorDomain && transientURLCodes.contains(node.code)) ||
      (node.domain == "AVFoundationErrorDomain" && node.code == -11819)
    let underlying = node.userInfo[NSUnderlyingErrorKey] as? NSError
    let knownWrapper = node.domain == "AVFoundationErrorDomain" && node.code == -11800 && underlying != nil
    hasTransient = hasTransient || transient
    allowed = allowed && (transient || knownWrapper) && !terminalHTTP.contains(node.code)
    // Only typed responses and explicit numerical HTTP status metadata count as evidence.
    for (key, value) in node.userInfo {
      if let response = value as? HTTPURLResponse, terminalHTTP.contains(response.statusCode) {
        allowed = false
      }
      if ["HTTPStatusCode", "AVErrorHTTPStatusCodeKey"].contains(key),
         let number = value as? NSNumber, CFGetTypeID(number) != CFBooleanGetTypeID(),
         terminalHTTP.contains(number.intValue), number.doubleValue == Double(number.intValue) {
        allowed = false
      }
    }
    current = underlying
  }
  let complete = current == nil
  return LumioNativeErrorClassification(chain: chain, chainComplete: complete, transient: allowed && complete && hasTransient)
}

// The log array is append-only for an item. Observations during healthy playback
// establish a watermark; older HTTP errors remain diagnostic-only, not retry vetoes.
struct LumioLiveErrorHistory {
  private(set) var wasReady = false
  private(set) var liveDetected = false
  private var healthyLogCount = 0

  mutating func observeReady(live: Bool, logCount: Int? = nil) {
    wasReady = true
    liveDetected = liveDetected || live
    if let logCount = logCount { healthyLogCount = max(healthyLogCount, logCount) }
  }

  func currentStatusCodes(_ statuses: [Int]) -> [Int] {
    Array(statuses.dropFirst(min(healthyLogCount, statuses.count)))
  }

  mutating func reset() { self = LumioLiveErrorHistory() }
}
