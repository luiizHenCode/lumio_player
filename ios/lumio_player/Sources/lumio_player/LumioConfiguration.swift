import CoreFoundation
import Foundation

struct LumioFailure: Error {
  let code: String
  let message: String
  let details: Any?
  init(_ code: String, _ message: String, details: Any? = nil) {
    self.code = code
    self.message = message
    self.details = details
  }
}

func lumioNumber(_ map: [String: Any], _ key: String, minimum: Double, maximum: Double = Double(Int64.max) / 2) throws -> Double {
  guard let value = map[key] as? NSNumber, CFGetTypeID(value) != CFBooleanGetTypeID(),
        value.doubleValue.isFinite, value.doubleValue >= minimum, value.doubleValue <= maximum else {
    throw LumioFailure("invalid_argument", "\(key) must be a finite number between \(minimum) and \(maximum).")
  }
  return value.doubleValue
}

func lumioPlaylistIndex(_ map: [String: Any], length: Int) throws -> Int {
  guard length > 0 else {
    throw LumioFailure("invalid_argument", "sources must be a nonempty list of source maps.")
  }
  let value = try lumioNumber(map, "index", minimum: 0, maximum: Double(length - 1))
  guard value.rounded() == value else {
    throw LumioFailure("invalid_argument", "index must be an integer.")
  }
  return Int(value)
}

struct LumioConfiguration {
  var live = false
  var autoPlay = false
  var looping = false
  var loopPlaylist = false
  var volume: Double = 1
  var speed: Double = 1
  var buffers: [String: Double] = [:]
  var liveTargetOffsetMs: Double?
  var enableDecoderFallback: Bool?

  init(_ map: [String: Any]) throws {
    for key in ["live", "autoPlay", "looping", "loopPlaylist"] where map[key] != nil {
      guard let value = map[key] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
        throw LumioFailure("invalid_argument", "\(key) must be a boolean.")
      }
      switch key {
      case "live": live = value.boolValue
      case "autoPlay": autoPlay = value.boolValue
      case "looping": looping = value.boolValue
      default: loopPlaylist = value.boolValue
      }
    }
    if map["liveTargetOffsetMs"] != nil {
      liveTargetOffsetMs = try lumioNumber(map, "liveTargetOffsetMs", minimum: 0, maximum: 60_000)
    }
    if let raw = map["enableDecoderFallback"] {
      guard let value = raw as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
        throw LumioFailure("invalid_argument", "enableDecoderFallback must be a boolean.")
      }
      enableDecoderFallback = value.boolValue
    }
    if map["volume"] != nil { volume = try lumioNumber(map, "volume", minimum: 0, maximum: 1) }
    if map["speed"] != nil { speed = try lumioNumber(map, "speed", minimum: 0.01, maximum: 4) }
    for key in ["bufferMinMs", "bufferMaxMs", "bufferPlaybackMs", "bufferRebufferMs"] where map[key] != nil {
      buffers[key] = try lumioNumber(map, key, minimum: 0, maximum: 86_400_000)
    }
    if let min = buffers["bufferMinMs"], let max = buffers["bufferMaxMs"], min > max {
      throw LumioFailure("invalid_argument", "bufferMinMs must not exceed bufferMaxMs.")
    }
  }
}
