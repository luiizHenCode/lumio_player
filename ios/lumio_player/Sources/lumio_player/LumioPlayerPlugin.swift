import AVFoundation
import Flutter
import UIKit

public final class LumioPlayerPlugin: NSObject, FlutterPlugin, FlutterStreamHandler {
  private let registrar: FlutterPluginRegistrar
  private var players: [Int64: LumioNativePlayer] = [:]
  private var nextID: Int64 = 1
  private var eventSink: FlutterEventSink?
  private var events: FlutterEventChannel?
  private var detached = false

  private init(registrar: FlutterPluginRegistrar) {
    self.registrar = registrar
    super.init()
  }

  public static func register(with registrar: FlutterPluginRegistrar) {
    let instance = LumioPlayerPlugin(registrar: registrar)
    let methods = FlutterMethodChannel(name: "lumio_player/methods", binaryMessenger: registrar.messenger())
    registrar.addMethodCallDelegate(instance, channel: methods)
    // Flutter only delivers engine-detach callbacks to a published instance.
    registrar.publish(instance)
    let events = FlutterEventChannel(name: "lumio_player/events", binaryMessenger: registrar.messenger())
    events.setStreamHandler(instance)
    instance.events = events
  }

  public func handle(_ call: FlutterMethodCall, result: @escaping FlutterResult) {
    guard Thread.isMainThread else {
      DispatchQueue.main.async { self.handle(call, result: result) }
      return
    }
    guard !detached else {
      result(FlutterError(code: "disposed", message: "The Flutter engine is detached.", details: nil))
      return
    }
    let arguments = call.arguments as? [String: Any] ?? [:]
    if call.method == "create" {
      let id = nextID
      nextID += 1
      let player = LumioNativePlayer(id: id, registry: registrar.textures()) { [weak self] event in
        self?.eventSink?(event)
      }
      players[id] = player
      result(["id": id, "textureId": player.textureID])
      return
    }
    let known = ["open", "openPlaylist", "selectPlaylistItem", "play", "pause", "seek", "seekToLive", "volume", "speed", "looping", "dispose", "diagnostics"]
    guard known.contains(call.method) else {
      result(FlutterMethodNotImplemented)
      return
    }
    guard let number = arguments["id"] as? NSNumber,
          CFGetTypeID(number) != CFBooleanGetTypeID(),
          number.doubleValue.isFinite, number.doubleValue >= 1,
          number.doubleValue <= Double(Int64.max / 2),
          number.doubleValue.rounded() == number.doubleValue,
          let player = players[number.int64Value] else {
      result(FlutterError(code: "invalid_player", message: "A valid player id is required.", details: nil))
      return
    }
    do {
      switch call.method {
      case "open":
        guard let source = arguments["source"] as? [String: Any] else {
          throw LumioFailure("invalid_argument", "source must be a map.")
        }
        if let config = arguments["config"], !(config is [String: Any]) {
          throw LumioFailure("invalid_argument", "config must be a map.")
        }
        let config = try LumioConfiguration(arguments["config"] as? [String: Any] ?? [:])
        let prepared = try assetSource(source)
        try lumioConfigureAudioSession(config.audioPolicy)
        player.openPlaylist(sources: [prepared], index: 0, configuration: config)
        result(nil)
      case "openPlaylist":
        guard let sources = arguments["sources"] as? [[String: Any]], !sources.isEmpty else {
          throw LumioFailure("invalid_argument", "sources must be a nonempty list of source maps.")
        }
        let index = try lumioPlaylistIndex(arguments, length: sources.count)
        if let config = arguments["config"], !(config is [String: Any]) {
          throw LumioFailure("invalid_argument", "config must be a map.")
        }
        let config = try LumioConfiguration(arguments["config"] as? [String: Any] ?? [:])
        // Validate every source before changing the existing queue.
        let prepared = try sources.map { try assetSource($0) }
        try lumioConfigureAudioSession(config.audioPolicy)
        player.openPlaylist(sources: prepared, index: index, configuration: config)
        result(nil)
      case "selectPlaylistItem":
        let index = try lumioPlaylistIndex(arguments, length: player.playlistLength)
        player.selectPlaylistItem(index: index)
        result(nil)
      case "play": player.play(); result(nil)
      case "pause": player.pause(); result(nil)
      case "seek":
        let milliseconds = try lumioNumber(arguments, "positionMs", minimum: 0)
        player.seek(milliseconds: milliseconds, result: result)
      case "seekToLive": try player.seekToLive(result: result)
      case "volume":
        player.setVolume(try lumioNumber(arguments, "volume", minimum: 0, maximum: 1))
        result(nil)
      case "speed":
        player.setSpeed(try lumioNumber(arguments, "speed", minimum: 0.01, maximum: 4))
        result(nil)
      case "looping":
        guard let value = arguments["looping"] as? NSNumber, CFGetTypeID(value) == CFBooleanGetTypeID() else {
          throw LumioFailure("invalid_argument", "looping must be a boolean.")
        }
        player.setLooping(value.boolValue)
        result(nil)
      case "dispose":
        players.removeValue(forKey: player.id)
        player.dispose()
        result(nil)
      case "diagnostics": result(player.diagnostics())
      default: result(FlutterMethodNotImplemented)
      }
    } catch let failure as LumioFailure {
      player.report(failure)
      result(FlutterError(code: failure.code, message: failure.message, details: failure.details))
    } catch {
      let failure = LumioFailure("native_error", "The native operation failed.")
      player.report(failure)
      result(FlutterError(code: failure.code, message: failure.message, details: nil))
    }
  }

  private func assetSource(_ source: [String: Any]) throws -> LumioAssetSource {
    let headers = try lumioHTTPHeaders(source)
    return LumioAssetSource(url: try sourceURL(source), headers: headers)
  }

  private func sourceURL(_ source: [String: Any]) throws -> URL {
    guard let type = source["type"] as? String,
          let uri = source["uri"] as? String, !uri.isEmpty else {
      throw LumioFailure("invalid_source", "source.type and a nonempty source.uri are required.")
    }
    if let format = source["format"], !(format is String) {
      throw LumioFailure("invalid_argument", "source.format must be a string.")
    }
    let format = source["format"] as? String ?? "auto"
    guard ["auto", "hls", "progressive", "dash", "rtsp"].contains(format) else {
      throw LumioFailure("unsupported_format", "Unknown source format.")
    }
    guard format != "dash", format != "rtsp" else {
      throw LumioFailure("unsupported_format", "AVPlayer does not support DASH or RTSP.")
    }

    let url: URL
    switch type {
    case "network":
      guard let parsed = URL(string: uri), let scheme = parsed.scheme?.lowercased() else {
        throw LumioFailure("invalid_source", "A valid HTTP(S) URL is required.")
      }
      guard scheme != "rtsp", scheme != "rtsps", parsed.pathExtension.lowercased() != "mpd" else {
        throw LumioFailure("unsupported_format", "AVPlayer does not support DASH or RTSP.")
      }
      guard ["http", "https"].contains(scheme), parsed.host != nil else {
        throw LumioFailure("invalid_source", "Network sources must use HTTP or HTTPS.")
      }
      url = parsed
    case "file":
      if let parsed = URL(string: uri), parsed.isFileURL {
        url = parsed
      } else {
        guard uri.hasPrefix("/") else {
          throw LumioFailure("invalid_source", "File sources must be absolute paths or file URLs.")
        }
        url = URL(fileURLWithPath: uri)
      }
    case "asset":
      let key = registrar.lookupKey(forAsset: uri)
      guard let path = Bundle.main.path(forResource: key, ofType: nil) else {
        throw LumioFailure("asset_not_found", "Flutter asset was not found.")
      }
      url = URL(fileURLWithPath: path)
    default: throw LumioFailure("invalid_source", "Unknown source type.")
    }
    if url.pathExtension.lowercased() == "mpd" {
      throw LumioFailure("unsupported_format", "AVPlayer does not support DASH.")
    }
    if url.isFileURL && !FileManager.default.isReadableFile(atPath: url.path) {
      throw LumioFailure("file_not_found", "The source file does not exist or is not readable.")
    }
    return url
  }


  public func onListen(withArguments arguments: Any?, eventSink events: @escaping FlutterEventSink) -> FlutterError? {
    eventSink = events
    for player in players.values { player.emitState() }
    return nil
  }

  public func onCancel(withArguments arguments: Any?) -> FlutterError? {
    eventSink = nil
    return nil
  }

  public func detachFromEngine(for registrar: FlutterPluginRegistrar) {
    detached = true
    for player in players.values { player.dispose() }
    players.removeAll()
    eventSink = nil
    events?.setStreamHandler(nil)
    events = nil
  }
}
