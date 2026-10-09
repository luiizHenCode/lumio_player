import AVFoundation
import Flutter
import UIKit

// CADisplayLink retains its target; this proxy keeps the player disposable.
private final class LumioDisplayTarget: NSObject {
  weak var owner: LumioNativePlayer?
  @objc func tick(_ link: CADisplayLink) { owner?.copyVideoFrame() }
}

final class LumioNativePlayer: NSObject, FlutterTexture {
  let id: Int64
  private(set) var textureID: Int64 = -1
  private let registry: FlutterTextureRegistry
  private let emit: ([String: Any]) -> Void
  private let player = AVQueuePlayer()
  private var currentItemObservation: NSKeyValueObservation?
  private var rebuildingQueue = false
  private var playlistURLs: [URL] = []
  private var queuedIndices: [ObjectIdentifier: Int] = [:]
  private var playlistIndex = 0
  var playlistLength: Int { playlistURLs.count }
  private var item: AVPlayerItem?
  private var output: AVPlayerItemVideoOutput?
  private var observations: [NSKeyValueObservation] = []
  private var itemNotifications: [NSObjectProtocol] = []
  private var lifecycleNotifications: [NSObjectProtocol] = []
  private var timer: Timer?
  private var displayLink: CADisplayLink?
  private let displayTarget = LumioDisplayTarget()
  // Flutter calls copyPixelBuffer on the raster thread, independently of main.
  private let pixelLock = NSLock()
  private var pixelBuffer: CVPixelBuffer?
  private var disposed = false
  private var generation = 0
  private var configuration = try! LumioConfiguration([:])
  private var wantsPlayback = false
  private var completed = false
  private var seeking = false
  private var seekSerial = 0
  private var background = false
  private var resumeAfterInterruption = false
  private var lastFailure: [String: Any]?
  private var accessLog: [[String: Any]] = []
  private var errorLog: [[String: Any]] = []

  init(id: Int64, registry: FlutterTextureRegistry, emit: @escaping ([String: Any]) -> Void) {
    self.id = id
    self.registry = registry
    self.emit = emit
    super.init()
    textureID = registry.register(self)
    displayTarget.owner = self
    player.actionAtItemEnd = .pause
    currentItemObservation = player.observe(\.currentItem, options: [.new]) { [weak self] player, _ in
      let next = player.currentItem
      let observedGeneration = self?.generation
      let update = { [weak self] in
        guard let self = self, !self.disposed, !self.rebuildingQueue,
              self.generation == observedGeneration, self.player.currentItem === next else { return }
        self.bindCurrentItem(next)
      }
      if Thread.isMainThread { update() } else { DispatchQueue.main.async(execute: update) }
    }
    background = UIApplication.shared.applicationState == .background
    observeLifecycle()
    timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in self?.emitState() }
    if let timer = timer { RunLoop.main.add(timer, forMode: .common) }
  }

  func open(url: URL, configuration: LumioConfiguration) {
    openPlaylist(urls: [url], index: 0, configuration: configuration)
  }

  func openPlaylist(urls: [URL], index: Int, configuration: LumioConfiguration) {
    playlistURLs = urls
    self.configuration = configuration
    completed = false
    lastFailure = nil
    accessLog.removeAll()
    errorLog.removeAll()
    wantsPlayback = configuration.autoPlay
    resumeAfterInterruption = false
    player.volume = Float(configuration.volume)
    player.automaticallyWaitsToMinimizeStalling = true
    rebuildQueue(index: index)
  }

  // Selection deliberately pauses. The parent sends play if playback is intended.
  func selectPlaylistItem(index: Int) {
    wantsPlayback = false
    resumeAfterInterruption = false
    rebuildQueue(index: index)
  }

  private func rebuildQueue(index: Int) {
    rebuildingQueue = true
    player.pause()
    clearItem()
    player.removeAllItems()
    queuedIndices.removeAll()
    playlistIndex = index
    var previous: AVPlayerItem?
    for position in index..<playlistURLs.count {
      let queued = AVPlayerItem(asset: AVURLAsset(url: playlistURLs[position]))
      // This is a preference, not a hard maximum. AVPlayer owns buffering policy.
      queued.preferredForwardBufferDuration =
        (configuration.buffers["bufferMaxMs"] ?? configuration.buffers["bufferMinMs"] ?? 0) / 1000
      queuedIndices[ObjectIdentifier(queued)] = position
      player.insert(queued, after: previous)
      previous = queued
    }
    rebuildingQueue = false
    bindCurrentItem(player.currentItem)
  }

  private func bindCurrentItem(_ next: AVPlayerItem?) {
    guard item !== next else { return }
    clearItem()
    completed = false
    lastFailure = nil
    accessLog.removeAll()
    errorLog.removeAll()
    guard let item = next, let index = queuedIndices[ObjectIdentifier(item)] else {
      emitState()
      return
    }
    playlistIndex = index
    // Keep the last item installed so completion, final position and replay work.
    player.actionAtItemEnd = configuration.looping || index == playlistURLs.count - 1 ? .pause : .advance
    let output = AVPlayerItemVideoOutput(pixelBufferAttributes: [
      kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32BGRA,
      kCVPixelBufferIOSurfacePropertiesKey as String: [String: String]()
    ])
    item.add(output)
    self.item = item
    self.output = output

    let currentGeneration = generation
    let changed: (@escaping (LumioNativePlayer) -> Void) -> Void = { [weak self, weak item] action in
      DispatchQueue.main.async { [weak self, weak item] in
        guard let self = self, !self.disposed, self.generation == currentGeneration,
              self.item === item, self.player.currentItem === item else { return }
        action(self)
      }
    }
    observations.append(item.observe(\.status, options: [.initial, .new]) { _, _ in
      changed { owner in
        if owner.item?.status == .failed {
          owner.wantsPlayback = false
          owner.player.pause()
          owner.reportNativeError(owner.item?.error, code: "open_failed")
        } else if owner.item?.status == .readyToPlay {
          owner.updateDisplayLink()
          if owner.wantsPlayback && !owner.completed { owner.player.rate = Float(owner.configuration.speed) }
        }
        owner.emitState()
      }
    })
    observations.append(item.observe(\.presentationSize, options: [.new]) { _, _ in
      changed { $0.updateDisplayLink(); $0.emitState() }
    })
    observations.append(item.observe(\.isPlaybackBufferEmpty, options: [.new]) { _, _ in
      changed { $0.emitState() }
    })
    observations.append(item.observe(\.isPlaybackLikelyToKeepUp, options: [.new]) { _, _ in
      changed { $0.emitState() }
    })
    observations.append(item.observe(\.loadedTimeRanges, options: [.new]) { _, _ in
      changed { $0.emitState() }
    })
    observations.append(player.observe(\.timeControlStatus, options: [.new]) { _, _ in
      changed { $0.emitState() }
    })
    observeItem(.AVPlayerItemDidPlayToEndTime, item: item) { owner, _ in owner.didEnd() }
    observeItem(.AVPlayerItemFailedToPlayToEndTime, item: item) { owner, notification in
      owner.wantsPlayback = false
      owner.player.pause()
      owner.reportNativeError(notification.userInfo?[AVPlayerItemFailedToPlayToEndTimeErrorKey] as? Error, code: "playback_failed")
      owner.emitState()
    }
    observeItem(.AVPlayerItemPlaybackStalled, item: item) { owner, _ in
      owner.emitState()
    }
    observeItem(.AVPlayerItemNewAccessLogEntry, item: item) { owner, _ in owner.captureLogs() }
    observeItem(.AVPlayerItemNewErrorLogEntry, item: item) { owner, _ in owner.captureLogs() }
    emitState()
  }

  private func observeItem(_ name: Notification.Name, item: AVPlayerItem,
                           action: @escaping (LumioNativePlayer, Notification) -> Void) {
    let currentGeneration = generation
    itemNotifications.append(NotificationCenter.default.addObserver(forName: name, object: item, queue: .main) { [weak self, weak item] notification in
      guard let self = self, !self.disposed, self.generation == currentGeneration,
            self.item === item, self.player.currentItem === item else { return }
      action(self, notification)
    })
  }

  private func observeLifecycle() {
    let center = NotificationCenter.default
    lifecycleNotifications.append(center.addObserver(forName: UIApplication.didEnterBackgroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.background = true
      self?.updateDisplayLink()
    })
    lifecycleNotifications.append(center.addObserver(forName: UIApplication.willEnterForegroundNotification, object: nil, queue: .main) { [weak self] _ in
      self?.background = false
      self?.updateDisplayLink()
      self?.emitState()
    })
    lifecycleNotifications.append(center.addObserver(forName: AVAudioSession.interruptionNotification, object: nil, queue: .main) { [weak self] note in
      guard let self = self, !self.disposed,
            let value = note.userInfo?[AVAudioSessionInterruptionTypeKey] as? NSNumber,
            let type = AVAudioSession.InterruptionType(rawValue: value.uintValue) else { return }
      if type == .began {
        let shouldResume = self.wantsPlayback
        self.pause()
        self.resumeAfterInterruption = shouldResume
      } else {
        let options = (note.userInfo?[AVAudioSessionInterruptionOptionKey] as? NSNumber)?.uintValue ?? 0
        let resume = self.resumeAfterInterruption
        self.resumeAfterInterruption = false
        if resume && AVAudioSession.InterruptionOptions(rawValue: options).contains(.shouldResume) {
          self.play()
        }
      }
    })
    lifecycleNotifications.append(center.addObserver(forName: AVAudioSession.routeChangeNotification, object: nil, queue: .main) { [weak self] note in
      let reason = (note.userInfo?[AVAudioSessionRouteChangeReasonKey] as? NSNumber)?.uintValue
      if reason == AVAudioSession.RouteChangeReason.oldDeviceUnavailable.rawValue {
        self?.resumeAfterInterruption = false
        self?.pause()
      }
    })
  }

  func play() {
    guard !disposed, item != nil, item?.status != .failed else { return }
    resumeAfterInterruption = false
    wantsPlayback = true
    if completed {
      completed = false
      let currentGeneration = generation
      player.seek(to: .zero) { [weak self] finished in
        DispatchQueue.main.async {
          guard let self = self, finished, !self.disposed,
                self.generation == currentGeneration, self.wantsPlayback else { return }
          self.player.rate = Float(self.configuration.speed)
          self.emitState()
        }
      }
    } else if item?.status == .readyToPlay {
      player.rate = Float(configuration.speed)
    }
    emitState()
  }

  func pause() {
    resumeAfterInterruption = false
    wantsPlayback = false
    player.pause()
    emitState()
  }

  func seek(milliseconds: Double, result: @escaping FlutterResult) {
    guard let item = item, item.status == .readyToPlay else {
      result(FlutterError(code: "not_initialized", message: "Wait for initialized before seeking.", details: nil))
      return
    }
    let duration = CMTimeGetSeconds(item.duration)
    let seconds = duration.isFinite ? min(milliseconds / 1000, max(0, duration)) : milliseconds / 1000
    seek(to: CMTime(seconds: seconds, preferredTimescale: 1000), result: result)
  }

  func seekToLive(result: @escaping FlutterResult) throws {
    guard let item = item, item.status == .readyToPlay else {
      throw LumioFailure("unsupported_live_seek", "A ready live item with a seekable range is required.")
    }
    let target = try lumioLiveSeekTarget(duration: item.duration,
      ranges: item.seekableTimeRanges.map { $0.timeRangeValue }, liveHint: configuration.live)
    // Live range times are authoritative and may exceed a finite reported duration.
    // Do not route through the VOD duration clamp in seek(milliseconds:result:).
    seek(to: target, result: result)
  }

  private func seek(to target: CMTime, result: @escaping FlutterResult) {
    completed = false
    seeking = true
    seekSerial += 1
    let serial = seekSerial
    let currentGeneration = generation
    player.seek(to: target, toleranceBefore: .zero, toleranceAfter: .zero) { [weak self] finished in
      DispatchQueue.main.async {
        guard let self = self, !self.disposed, self.generation == currentGeneration else {
          result(FlutterError(code: "disposed", message: "Player was disposed or its source changed during seek.", details: nil))
          return
        }
        guard self.seekSerial == serial else {
          result(FlutterError(code: "seek_cancelled", message: "Seek was superseded by another seek.", details: nil))
          return
        }
        self.seeking = false
        if finished && self.wantsPlayback { self.player.rate = Float(self.configuration.speed) }
        self.copyVideoFrame()
        self.emitState()
        if finished { result(nil) } else {
          result(FlutterError(code: "seek_cancelled", message: "Seek was interrupted by another operation.", details: nil))
        }
      }
    }
    emitState()
  }

  func setVolume(_ value: Double) {
    configuration.volume = value
    player.volume = Float(value)
    emitState()
  }

  func setSpeed(_ value: Double) {
    configuration.speed = value
    if wantsPlayback && item?.status == .readyToPlay { player.rate = Float(value) }
    emitState()
  }

  func setLooping(_ value: Bool) {
    configuration.looping = value
    player.actionAtItemEnd = value || playlistIndex == playlistURLs.count - 1 ? .pause : .advance
    emitState()
  }

  private func didEnd() {
    // Ordinary transitions are owned by AVQueuePlayer, never by Flutter.
    if !configuration.looping && playlistIndex < playlistURLs.count - 1 { return }
    if wantsPlayback && (configuration.looping || configuration.loopPlaylist) {
      rebuildQueue(index: configuration.looping ? playlistIndex : 0)
    } else {
      completed = true
      wantsPlayback = false
      player.pause()
      emitState()
    }
  }

  private func updateDisplayLink() {
    let hasVideo = (item?.presentationSize.width ?? 0) > 0 && (item?.presentationSize.height ?? 0) > 0
    if hasVideo && displayLink == nil {
      let link = CADisplayLink(target: displayTarget, selector: #selector(LumioDisplayTarget.tick(_:)))
      link.preferredFramesPerSecond = 60
      link.add(to: .main, forMode: .common)
      displayLink = link
    }
    displayLink?.isPaused = background || !hasVideo
  }

  fileprivate func copyVideoFrame() {
    guard !disposed, !background, let output = output, item?.status == .readyToPlay,
          item === player.currentItem else { return }
    let time = output.itemTime(forHostTime: CACurrentMediaTime())
    guard output.hasNewPixelBuffer(forItemTime: time),
          let buffer = output.copyPixelBuffer(forItemTime: time, itemTimeForDisplay: nil) else { return }
    pixelLock.lock()
    pixelBuffer = buffer
    pixelLock.unlock()
    registry.textureFrameAvailable(textureID)
  }

  func copyPixelBuffer() -> Unmanaged<CVPixelBuffer>? {
    pixelLock.lock()
    defer { pixelLock.unlock() }
    guard let buffer = pixelBuffer else { return nil }
    return Unmanaged.passRetained(buffer)
  }

  func emitState() {
    guard !disposed else { return }
    // AVFoundation may change currentItem off-main before its KVO handoff arrives.
    if !rebuildingQueue && item !== player.currentItem {
      bindCurrentItem(player.currentItem)
      return
    }
    let position = milliseconds(player.currentTime())
    let duration = item.map { milliseconds($0.duration) } ?? 0
    var buffered = position
    for range in item?.loadedTimeRanges ?? [] {
      let timeRange = range.timeRangeValue
      let start = milliseconds(timeRange.start)
      let end = milliseconds(CMTimeRangeGetEnd(timeRange))
      if start <= position + 100 && end >= position { buffered = max(buffered, end) }
    }
    let size = item?.presentationSize ?? .zero
    let initialized = item?.status == .readyToPlay
    let buffering = item != nil && item?.status != .failed && !completed &&
      (!initialized || seeking || (wantsPlayback && (player.timeControlStatus == .waitingToPlayAtSpecifiedRate || item?.isPlaybackBufferEmpty == true)))
    emit([
      "id": id, "type": "state", "initialized": initialized,
      "playing": player.timeControlStatus == .playing, "buffering": buffering,
      "completed": completed, "positionMs": position, "durationMs": duration,
      "width": dimension(size.width), "height": dimension(size.height),
      "bufferedPositionMs": buffered,
      "live": configuration.live || (initialized && item?.duration.isIndefinite == true),
      "volume": configuration.volume, "speed": configuration.speed,
      "playlistIndex": playlistIndex, "playlistLength": playlistLength
    ])
  }

  private func milliseconds(_ time: CMTime) -> Int64 {
    let value = CMTimeGetSeconds(time) * 1000
    guard value.isFinite, value > 0 else { return 0 }
    return Int64(min(value, Double(Int64.max / 2)))
  }

  private func dimension(_ value: CGFloat) -> Int {
    guard value.isFinite, value > 0 else { return 0 }
    return Int(min(value, CGFloat(Int32.max)).rounded())
  }

  func report(_ failure: LumioFailure, recoverable: Bool = true) {
    guard !disposed else { return }
    let event: [String: Any] = [
      "id": id, "type": "error", "code": failure.code, "message": failure.message,
      "details": failure.details ?? NSNull(), "recoverable": recoverable
    ]
    lastFailure = event
    emit(event)
  }

  private func reportNativeError(_ error: Error?, code: String) {
    let native = error as NSError?
    // Native descriptions/userInfo can contain signed URLs or credentials.
    report(LumioFailure(code, "AVFoundation could not play the current item.", details: [
      "nativeCode": native?.code ?? 0
    ]), recoverable: false)
    captureLogs()
  }

  private func captureLogs() {
    // Bound diagnostic payloads and avoid returning URLs which may contain credentials.
    accessLog = (item?.accessLog()?.events.suffix(30) ?? []).map { event in
      ["numberOfStalls": event.numberOfStalls,
       "numberOfBytesTransferred": event.numberOfBytesTransferred,
       "observedBitrate": finite(event.observedBitrate),
       "indicatedBitrate": finite(event.indicatedBitrate),
       "transferDuration": finite(event.transferDuration),
       "durationWatched": finite(event.durationWatched)]
    }
    errorLog = (item?.errorLog()?.events.suffix(30) ?? []).map { event in
      ["date": event.date?.timeIntervalSince1970 ?? 0,
       "code": event.errorStatusCode]
    }
  }

  private func finite(_ value: Double) -> Double { value.isFinite ? value : 0 }

  private var mediaStatistics: [String: Any] = [:]
  private var statisticsTask: Task<Void, Never>?
  private var statisticsItem: AVPlayerItem?

  private func loadMediaStatistics() {
    guard let current = item, statisticsItem !== current else { return }
    statisticsTask?.cancel()
    statisticsItem = current
    mediaStatistics = [:]
    guard #available(iOS 15.0, *) else { return }
    statisticsTask = Task { @MainActor [weak self, weak current] in
      guard let current = current else { return }
      do {
        var result: [String: Any] = [:]
        for type in [AVMediaType.video, AVMediaType.audio] {
          let tracks = try await current.asset.loadTracks(withMediaType: type)
          guard let track = tracks.first else { continue }
          let descriptions = try await track.load(.formatDescriptions)
          if let description = descriptions.first {
            let code = CMFormatDescriptionGetMediaSubType(description)
            let bytes: [UInt8] = [UInt8((code >> 24) & 255), UInt8((code >> 16) & 255), UInt8((code >> 8) & 255), UInt8(code & 255)]
            result[type == .video ? "videoCodec" : "audioCodec"] = String(bytes: bytes, encoding: .ascii) ?? "unknown"
          }
          let bitrate = try await track.load(.estimatedDataRate)
          if bitrate.isFinite && bitrate > 0 { result[type == .video ? "videoBitrate" : "audioBitrate"] = bitrate }
          if type == .video {
            let fps = try await track.load(.nominalFrameRate)
            if fps.isFinite && fps > 0 { result["frameRate"] = fps }
          }
        }
        guard !Task.isCancelled, let self = self, !self.disposed, self.item === current else { return }
        self.mediaStatistics = result
      } catch {
        // Metadata availability must never affect playback or expose asset URLs.
      }
    }
  }

  func diagnostics() -> [String: Any] {
    captureLogs()
    loadMediaStatistics()
    let session = AVAudioSession.sharedInstance()
    return [
      "id": id, "backend": "AVQueuePlayer", "textureId": textureID,
      "device": ["platform": "iOS", "model": UIDevice.current.model, "systemVersion": UIDevice.current.systemVersion],
      "media": mediaStatistics,
      "decoderName": NSNull(), // AVPlayer does not expose the selected decoder.
      "metadataPolicy": "Track metadata is asynchronous and may be unavailable for live HLS.",
      "playlistIndex": playlistIndex, "playlistLength": playlistLength,
      "loopPlaylist": configuration.loopPlaylist,
      "itemStatus": item?.status.rawValue ?? AVPlayerItem.Status.unknown.rawValue,
      "timeControlStatus": player.timeControlStatus.rawValue,
      "waitingReason": player.reasonForWaitingToPlay?.rawValue ?? NSNull(),
      "requestedBufferMs": configuration.buffers,
      "preferredForwardBufferDurationMs": (item?.preferredForwardBufferDuration ?? 0) * 1000,
      "bufferPolicy": "bufferMaxMs (or bufferMinMs) is a forward-buffer preference, not a hard limit. Startup/rebuffer thresholds are managed by AVPlayer.",
      "unsupportedBufferSettings": ["bufferPlaybackMs", "bufferRebufferMs"],
      "liveTargetOffsetMs": configuration.liveTargetOffsetMs.map { $0 as Any } ?? NSNull(),
      "enableDecoderFallback": configuration.enableDecoderFallback.map { $0 as Any } ?? NSNull(),
      "unsupportedSettings": ["bufferPlaybackMs", "bufferRebufferMs", "liveTargetOffsetMs", "enableDecoderFallback"],
      "supportsCustomHeaders": false, "supportedFormats": ["auto", "hls", "progressive"],
      "audioSessionCategory": session.category.rawValue,
      "audioSessionMixesWithOthers": session.categoryOptions.contains(.mixWithOthers),
      "accessLog": accessLog, "errorLog": errorLog, "lastError": lastFailure ?? NSNull()
    ]
  }

  private func clearItem() {
    statisticsTask?.cancel()
    statisticsTask = nil
    statisticsItem = nil
    mediaStatistics = [:]
    generation += 1
    seeking = false
    item?.cancelPendingSeeks()
    observations.forEach { $0.invalidate() }
    observations.removeAll()
    itemNotifications.forEach { NotificationCenter.default.removeObserver($0) }
    itemNotifications.removeAll()
    displayLink?.invalidate()
    displayLink = nil
    if let output = output { item?.remove(output) }
    output = nil

    item = nil
    pixelLock.lock()
    pixelBuffer = nil
    pixelLock.unlock()
  }

  func dispose() {
    guard !disposed else { return }
    disposed = true
    wantsPlayback = false
    resumeAfterInterruption = false
    currentItemObservation?.invalidate()
    currentItemObservation = nil
    player.pause()
    timer?.invalidate()
    timer = nil
    clearItem()
    player.removeAllItems()
    playlistURLs.removeAll()
    queuedIndices.removeAll()
    lifecycleNotifications.forEach { NotificationCenter.default.removeObserver($0) }
    lifecycleNotifications.removeAll()
    displayTarget.owner = nil
    registry.unregisterTexture(textureID)
  }
}
