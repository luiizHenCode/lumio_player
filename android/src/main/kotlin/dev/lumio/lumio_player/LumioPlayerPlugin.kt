package dev.lumio.lumio_player

import android.content.Context
import android.media.MediaCodecList
import android.net.Uri
import android.os.Build
import android.os.Handler
import android.os.Looper
import androidx.media3.common.C
import androidx.media3.common.MediaItem
import androidx.media3.common.MimeTypes
import androidx.media3.common.PlaybackException
import androidx.media3.common.Player
import androidx.media3.common.VideoSize
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.DefaultDataSource
import androidx.media3.datasource.DefaultHttpDataSource
import androidx.media3.exoplayer.DefaultLoadControl
import androidx.media3.exoplayer.DefaultRenderersFactory
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.source.DefaultMediaSourceFactory
import androidx.media3.exoplayer.source.MediaSource
import io.flutter.embedding.engine.plugins.FlutterPlugin
import io.flutter.plugin.common.EventChannel
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import io.flutter.view.TextureRegistry
import java.io.File

@UnstableApi
class LumioPlayerPlugin : FlutterPlugin, MethodChannel.MethodCallHandler,
    EventChannel.StreamHandler {
    private var binding: FlutterPlugin.FlutterPluginBinding? = null
    private var methods: MethodChannel? = null
    private var events: EventChannel? = null
    private var sink: EventChannel.EventSink? = null
    private val players = linkedMapOf<Long, Instance>()
    private var nextId = 1L
    private var handler: Handler? = null
    private val tick = object : Runnable {
        override fun run() {
            players.values.toList().forEach { it.emitState() }
            if (players.isNotEmpty()) handler?.postDelayed(this, 500)
        }
    }

    override fun onAttachedToEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        this.binding = binding
        handler = Handler(Looper.getMainLooper())
        methods = MethodChannel(binding.binaryMessenger, "lumio_player/methods").also {
            it.setMethodCallHandler(this)
        }
        events = EventChannel(binding.binaryMessenger, "lumio_player/events").also {
            it.setStreamHandler(this)
        }
    }

    override fun onListen(arguments: Any?, events: EventChannel.EventSink) {
        sink = events
        players.values.forEach { instance ->
            instance.emitState()
            instance.lastError?.let { events.success(it) }
        }
    }

    override fun onCancel(arguments: Any?) {
        sink = null
    }

    override fun onMethodCall(call: MethodCall, result: MethodChannel.Result) {
        if (binding == null) {
            result.error("engine_detached", "The Flutter engine is not attached", null)
            return
        }
        val args = call.arguments as? Map<*, *> ?: emptyMap<Any, Any>()
        var instance: Instance? = null
        try {
            when (call.method) {
                "create" -> {
                    val engine = requireNotNull(binding)
                    val producer = engine.textureRegistry.createSurfaceProducer()
                    val id = nextId++
                    val created = try {
                        Instance(id, producer, engine.applicationContext)
                    } catch (error: Exception) {
                        producer.release()
                        throw error
                    }
                    players[id] = created
                    result.success(mapOf("id" to id, "textureId" to producer.id()))
                    created.emitState()
                    if (players.size == 1) handler?.postDelayed(tick, 500)
                    return
                }
                "diagnostics" -> {
                    val id = args["id"]
                    result.success(diagnostics(if (id == null) null else lookup(args)))
                    return
                }
                "open", "openPlaylist", "selectPlaylistItem", "play", "pause", "seek", "seekToLive", "volume", "speed", "looping", "dispose" -> {
                    instance = lookup(args)
                    when (call.method) {
                        "open" -> instance.open(args, playlist = false)
                                                "openPlaylist" -> instance.open(args, playlist = true)
                                                "selectPlaylistItem" -> instance.selectPlaylistItem(args)
                        "play" -> instance.player.play()
                        "pause" -> instance.player.pause()
                        "seek" -> {
                            val position = args.requiredNonNegativeLong("positionMs")
                            instance.player.seekTo(position)
                        }
                        "seekToLive" -> {
                            if (!instance.player.seekToLive()) {
                                result.error("unsupported_live_seek", "The current media item is not live", mapOf("id" to instance.id))
                                return
                            }
                        }
                        "volume" -> instance.player.volume = validVolume(args.requiredNumber("volume").toFloat())
                        "speed" -> instance.player.setPlaybackSpeed(validSpeed(args.requiredNumber("speed").toFloat()))
                        "looping" -> instance.setLooping(args.requiredBoolean("looping"))
                        "dispose" -> {
                            players.remove(instance.id)
                            instance.dispose()
                            if (players.isEmpty()) handler?.removeCallbacks(tick)
                        }
                    }
                    if (call.method != "dispose") instance.emitState()
                    result.success(null)
                }
                else -> result.notImplemented()
            }
        } catch (error: IllegalArgumentException) {
            result.error("invalid_argument", error.message, null)
        } catch (error: Exception) {
            val details = mapOf("exception" to error.javaClass.name, "method" to call.method)
            instance?.emitError("native_error", error.message ?: "Native playback operation failed", details, false)
            result.error("native_error", error.message, details)
        }
    }

    private fun lookup(args: Map<*, *>): Instance {
        val id = args.requiredNonNegativeLong("id")
        return players[id] ?: throw IllegalArgumentException("Unknown player id: $id")
    }

    override fun onDetachedFromEngine(binding: FlutterPlugin.FlutterPluginBinding) {
        methods?.setMethodCallHandler(null)
        events?.setStreamHandler(null)
        sink = null
        handler?.removeCallbacksAndMessages(null)
        // Release every player even if a vendor codec throws during release.
        players.values.toList().forEach { runCatching { it.dispose() } }
        players.clear()
        methods = null
        events = null
        handler = null
        this.binding = null
    }

    private fun diagnostics(instance: Instance?): Map<String, Any?> {
        val codecs = runCatching {
            MediaCodecList(MediaCodecList.REGULAR_CODECS).codecInfos.filter { !it.isEncoder }.map {
                buildMap<String, Any> {
                    put("name", it.name)
                    put("supportedTypes", it.supportedTypes.toList())
                    if (Build.VERSION.SDK_INT >= 29) {
                        put("hardwareAccelerated", it.isHardwareAccelerated)
                        put("softwareOnly", it.isSoftwareOnly)
                        put("vendor", it.isVendor)
                    }
                }
            }
        }.getOrDefault(emptyList())
        return mapOf(
            "engine" to "AndroidX Media3 ExoPlayer",
            "media3Version" to androidx.media3.common.MediaLibraryInfo.VERSION,
            "androidVersion" to Build.VERSION.RELEASE,
            "sdkInt" to Build.VERSION.SDK_INT,
            "manufacturer" to Build.MANUFACTURER,
            "model" to Build.MODEL,
            "supportedAbis" to Build.SUPPORTED_ABIS.toList(),
            "activePlayers" to players.size,
            "decoders" to codecs,
            "player" to instance?.diagnostics(),
        )
    }

    private inner class Instance(
        val id: Long,
        private val producer: TextureRegistry.SurfaceProducer,
        private val context: Context,
    ) : Player.Listener, AnalyticsListener, TextureRegistry.SurfaceProducer.Callback {
        var player: ExoPlayer = buildPlayer(PlaybackConfig())
            private set
        private var released = false
        private var hasSource = false
        private var initialized = false
        private var requestedLive = false
        private var surfaceAvailable = true
        private var sourceType: String? = null
        private var sourceFormat: String? = null
                private var sources = emptyList<PreparedSource>()
                private var loopPlaylist = false
        private var videoDecoderName: String? = null
        private var audioDecoderName: String? = null
        private var enableDecoderFallback = true
        private var liveTargetOffsetMs: Long? = null
        var lastError: Map<String, Any?>? = null
            private set

        init {
            try {
                producer.setSize(1, 1)
                producer.setCallback(this)
                player.addListener(this)
                player.addAnalyticsListener(this)
                player.setVideoSurface(producer.surface)
            } catch (error: Exception) {
                player.release()
                throw error
            }
        }

        private fun buildPlayer(config: PlaybackConfig): ExoPlayer {
            val loadControl = DefaultLoadControl.Builder().setBufferDurationsMs(
                config.bufferMinMs, config.bufferMaxMs,
                config.bufferPlaybackMs, config.bufferRebufferMs,
            ).build()
            val renderersFactory = DefaultRenderersFactory(context)
                .setEnableDecoderFallback(config.enableDecoderFallback)
            return ExoPlayer.Builder(context, renderersFactory).setLooper(Looper.getMainLooper())
                .setLoadControl(loadControl).build()
        }

        private fun prepareSource(source: Map<*, *>, config: PlaybackConfig): PreparedSource {
            val type = source["type"] as? String
                ?: throw IllegalArgumentException("source.type is required")
            val location = source["uri"] as? String
                ?: throw IllegalArgumentException("source.uri is required")
            require(location.isNotBlank()) { "source.uri must not be empty" }
            require(source["format"] == null || source["format"] is String) { "source.format must be a string" }
            val format = source["format"] as? String ?: "auto"
            val mime = when (format) {
                "auto" -> null
                "hls" -> MimeTypes.APPLICATION_M3U8
                "dash" -> MimeTypes.APPLICATION_MPD
                "progressive" -> MimeTypes.VIDEO_UNKNOWN
                "rtsp" -> MimeTypes.APPLICATION_RTSP
                else -> throw IllegalArgumentException("Unsupported source.format: $format")
            }
            val uri = when (type) {
                "network" -> Uri.parse(location).also {
                    require(it.scheme?.lowercase() in listOf("http", "https", "rtsp")) {
                        "Network sources require an http, https, or rtsp URI"
                    }
                }
                "file" -> {
                    val parsed = Uri.parse(location)
                    when (parsed.scheme) {
                        null -> Uri.fromFile(File(location))
                        "file", "content" -> parsed
                        else -> throw IllegalArgumentException("File sources require a path, file URI, or content URI")
                    }
                }
                "asset" -> {
                    val engine = requireNotNull(binding)
                    val packageName = source["package"] as? String
                    val key = if (packageName == null) engine.flutterAssets.getAssetFilePathByName(location)
                    else engine.flutterAssets.getAssetFilePathByName(location, packageName)
                    Uri.Builder().scheme("asset").path("/$key").build()
                }
                else -> throw IllegalArgumentException("Unsupported source.type: $type")
            }
            val headers = source["headers"]?.let { raw ->
                require(raw is Map<*, *>) { "source.headers must be a map" }
                raw.entries.associate { entry ->
                    require(entry.key is String && entry.value is String) { "Headers must contain string keys and values" }
                    entry.key as String to entry.value as String
                }
            } ?: emptyMap()
            val http = DefaultHttpDataSource.Factory().setDefaultRequestProperties(headers)
            val factory = DefaultMediaSourceFactory(DefaultDataSource.Factory(context, http))
            val item = MediaItem.Builder().setUri(uri).setMimeType(mime).apply {
                config.liveTargetOffsetMs?.let { offset ->
                    setLiveConfiguration(MediaItem.LiveConfiguration.Builder().setTargetOffsetMs(offset).build())
                }
            }.build()
            return PreparedSource(factory.createMediaSource(item), type, format)
        }

        fun open(args: Map<*, *>, playlist: Boolean) {
            val request = QueueRequest.parse(args, playlist)
            val config = PlaybackConfig.parse(args["config"])
            // Resolve and validate every source before disturbing the existing player.
            val prepared = request.sources.map { prepareSource(it, config) }
            // Buffer configuration belongs to the player, so reopen replaces it without replacing the texture.
            val replacement = buildPlayer(config)
            try {
                player.removeListener(this)
                player.removeAnalyticsListener(this)
                try {
                    player.clearVideoSurface()
                } finally {
                    player.release()
                }
            } catch (error: Exception) {
                runCatching { replacement.release() }
                throw error
            }
            player = replacement
            hasSource = true
            initialized = false
            requestedLive = config.live
            sources = prepared
            loopPlaylist = config.loopPlaylist
            sourceType = prepared[request.index].type
            sourceFormat = prepared[request.index].format
            videoDecoderName = null
            audioDecoderName = null
            enableDecoderFallback = config.enableDecoderFallback
            liveTargetOffsetMs = config.liveTargetOffsetMs
            lastError = null
            player.addListener(this)
            player.addAnalyticsListener(this)
            if (surfaceAvailable) player.setVideoSurface(producer.surface)
            player.volume = config.volume
            player.setPlaybackSpeed(config.speed)
            player.repeatMode = playlistRepeatMode(config.looping, loopPlaylist)
            player.loadPlaylist(prepared.map { it.mediaSource }, request.index, config.autoPlay)
        }

        fun setLooping(looping: Boolean) {
            player.repeatMode = playlistRepeatMode(looping, loopPlaylist)
        }

        fun selectPlaylistItem(args: Map<*, *>) {
            val index = args.playlistIndex(player.mediaItemCount)
            resetCurrentItem(index)
            player.selectPlaylistItem(index)
        }

        private fun resetCurrentItem(index: Int) {
            initialized = false
            lastError = null
            sourceType = sources.getOrNull(index)?.type
            sourceFormat = sources.getOrNull(index)?.format
        }

        override fun onMediaItemTransition(mediaItem: MediaItem?, reason: Int) {
            resetCurrentItem(player.currentMediaItemIndex)
            // onEvents emits the updated position/duration after the full transition batch.
        }

        override fun onSurfaceAvailable() {
            if (!released) {
                surfaceAvailable = true
                player.setVideoSurface(producer.surface)
            }
        }

        override fun onSurfaceCleanup() {
            if (!released) {
                surfaceAvailable = false
                player.clearVideoSurface()
            }
        }

        override fun onPlaybackStateChanged(playbackState: Int) {
            if (playbackState == Player.STATE_READY) initialized = true
        }

        override fun onVideoSizeChanged(videoSize: VideoSize) {
            if (!released && videoSize.width > 0 && videoSize.height > 0) {
                producer.setSize(videoSize.width, videoSize.height)
            }
        }

        override fun onVideoDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            if (!released) videoDecoderName = decoderName
        }

        override fun onAudioDecoderInitialized(
            eventTime: AnalyticsListener.EventTime,
            decoderName: String,
            initializedTimestampMs: Long,
            initializationDurationMs: Long,
        ) {
            if (!released) audioDecoderName = decoderName
        }

        override fun onVideoDecoderReleased(eventTime: AnalyticsListener.EventTime, decoderName: String) {
            if (videoDecoderName == decoderName) videoDecoderName = null
        }

        override fun onAudioDecoderReleased(eventTime: AnalyticsListener.EventTime, decoderName: String) {
            if (audioDecoderName == decoderName) audioDecoderName = null
        }

        override fun onEvents(player: Player, events: Player.Events) {
            // Seamless transitions may remain READY without a playback-state callback.
            if (player.playbackState == Player.STATE_READY) initialized = true
            emitState()
        }

        override fun onPlayerError(eventTime: AnalyticsListener.EventTime, error: PlaybackException) {
            val recoverable = error.errorCode in setOf(
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_FAILED,
                PlaybackException.ERROR_CODE_IO_NETWORK_CONNECTION_TIMEOUT,
                PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS,
                PlaybackException.ERROR_CODE_BEHIND_LIVE_WINDOW,
            )
            emitError(error.errorCodeName, error.message ?: "Playback failed", mapOf(
                "errorCode" to error.errorCode,
                "cause" to error.cause?.javaClass?.name,
                "causeMessage" to error.cause?.message,
                "playlistIndex" to eventTime.windowIndex,
            ), recoverable, eventTime.windowIndex)
        }

        fun emitError(
            code: String, message: String, details: Any?, recoverable: Boolean,
            playlistIndex: Int = player.currentMediaItemIndex,
        ) {
            if (released) return
            lastError = mapOf("id" to id, "type" to "error", "code" to code,
                "message" to message, "details" to details, "recoverable" to recoverable,
                                "playlistIndex" to playlistIndex, "playlistLength" to player.mediaItemCount)
            sink?.success(lastError)
        }

        private fun state(): Map<String, Any> = mapOf(
            "id" to id,
            "type" to "state",
            "playlistIndex" to player.currentMediaItemIndex,
            "playlistLength" to player.mediaItemCount,
            "initialized" to initialized,
            "playing" to player.isPlaying,
            "buffering" to (hasSource && player.playbackState == Player.STATE_BUFFERING),
            "completed" to (player.playbackState == Player.STATE_ENDED),
            "positionMs" to player.currentPosition.coerceAtLeast(0),
            "durationMs" to player.duration.let { if (it == C.TIME_UNSET) 0L else it.coerceAtLeast(0) },
            "width" to player.videoSize.width,
            "height" to player.videoSize.height,
            "bufferedPositionMs" to player.bufferedPosition.coerceAtLeast(0),
            "live" to (requestedLive || player.isCurrentMediaItemLive),
            "volume" to player.volume.toDouble(),
            "speed" to player.playbackParameters.speed.toDouble(),
        )

        fun emitState() {
            if (!released && sink != null) sink?.success(state())
        }

        fun diagnostics(): Map<String, Any?> = mapOf(
            "state" to state(),
            "textureId" to producer.id(),
            "surfaceAvailable" to surfaceAvailable,
            "handlesCropAndRotation" to producer.handlesCropAndRotation(),
            "sourceType" to sourceType,
            "sourceFormat" to sourceFormat,
            "videoMimeType" to player.videoFormat?.sampleMimeType,
            "videoCodecs" to player.videoFormat?.codecs,
            "audioMimeType" to player.audioFormat?.sampleMimeType,
            "audioCodecs" to player.audioFormat?.codecs,
            "videoBitrate" to player.videoFormat?.bitrate?.takeIf { it >= 0 },
            "audioBitrate" to player.audioFormat?.bitrate?.takeIf { it >= 0 },
            "frameRate" to player.videoFormat?.frameRate?.takeIf { it > 0 },
            "audioSampleRate" to player.audioFormat?.sampleRate?.takeIf { it > 0 },
            "audioChannels" to player.audioFormat?.channelCount?.takeIf { it > 0 },
            "bufferDurationMs" to player.totalBufferedDuration,
            "liveOffsetMs" to player.currentLiveOffset.takeIf { it != C.TIME_UNSET },
            "droppedVideoFrames" to player.videoDecoderCounters?.droppedBufferCount,
            "renderedVideoFrames" to player.videoDecoderCounters?.renderedOutputBufferCount,
            "videoDecoderName" to videoDecoderName,
            "audioDecoderName" to audioDecoderName,
            "enableDecoderFallback" to enableDecoderFallback,
            "liveTargetOffsetMs" to liveTargetOffsetMs,
            // Exception text can contain authenticated URLs or request headers.
            "lastError" to lastError?.filterKeys {
                it in setOf("id", "type", "code", "recoverable", "playlistIndex", "playlistLength")
            },
        )

        fun dispose() {
            if (released) return
            released = true
            try {
                producer.setCallback(null)
                player.removeListener(this)
                player.removeAnalyticsListener(this)
                player.clearVideoSurface()
            } finally {
                try {
                    player.release()
                } finally {
                    producer.release()
                }
            }
        }
    }
}

private data class PreparedSource(val mediaSource: MediaSource, val type: String, val format: String)

internal data class QueueRequest(val sources: List<Map<*, *>>, val index: Int) {
    companion object {
        fun parse(args: Map<*, *>, playlist: Boolean): QueueRequest {
            val sources = if (playlist) {
                val raw = args["sources"] as? List<*>
                    ?: throw IllegalArgumentException("sources must be a list")
                require(raw.isNotEmpty()) { "sources must not be empty" }
                raw.map { it as? Map<*, *> ?: throw IllegalArgumentException("Each source must be a map") }
            } else {
                listOf(args["source"] as? Map<*, *> ?: throw IllegalArgumentException("source must be a map"))
            }
            val index = if (playlist && args.containsKey("index")) args.playlistIndex(sources.size) else 0
            return QueueRequest(sources, index)
        }
    }
}

internal fun Map<*, *>.playlistIndex(length: Int): Int {
    val index = requiredNonNegativeLong("index")
    require(index < length) { "index must be within the playlist (length $length)" }
    return index.toInt()
}

internal fun playlistRepeatMode(looping: Boolean, loopPlaylist: Boolean): Int = when {
    looping -> Player.REPEAT_MODE_ONE
    loopPlaylist -> Player.REPEAT_MODE_ALL
    else -> Player.REPEAT_MODE_OFF
}

@UnstableApi
internal fun ExoPlayer.loadPlaylist(sources: List<MediaSource>, index: Int, autoPlay: Boolean) {
    require(sources.isNotEmpty() && index >= 0 && index < sources.size) { "Invalid playlist index" }
    setMediaSources(sources, index, 0L)
    playWhenReady = autoPlay
    prepare()
}

internal fun Player.selectPlaylistItem(index: Int) {
    require(index >= 0 && index < mediaItemCount) { "index must be within the playlist" }
    val shouldPlay = playWhenReady
    seekTo(index, 0L)
    // A seek exits ENDED; preparing also permits selection after a fatal item error.
    if (playbackState == Player.STATE_IDLE) prepare()
    playWhenReady = shouldPlay
}

internal fun Player.seekToLive(): Boolean {
    if (!isCurrentMediaItemLive) return false
    seekToDefaultPosition()
    return true
}

internal fun Map<*, *>.requiredNumber(key: String): Number {
    val value = this[key] as? Number ?: throw IllegalArgumentException("$key must be a number")
    require(value.toDouble().isFinite()) { "$key must be finite" }
    return value
}

internal fun Map<*, *>.requiredNonNegativeLong(key: String): Long {
    val number = requiredNumber(key)
    // Validate floating point channel values without rounding IDs or saturating an overflowing seek.
    val value = number.toDouble()
    require(value >= 0 && value % 1 == 0.0) { "$key must be a non-negative integer" }
    if (number !is Long && number !is Int) {
        require(value < 9_223_372_036_854_775_808.0) { "$key exceeds the 64-bit integer range" }
    }
    return number.toLong()
}

internal fun Map<*, *>.requiredBoolean(key: String): Boolean =
    this[key] as? Boolean ?: throw IllegalArgumentException("$key must be a boolean")

internal fun validVolume(value: Float): Float {
    require(value.isFinite() && value in 0f..1f) { "volume must be between 0 and 1" }
    return value
}

internal fun validSpeed(value: Float): Float {
    require(value.isFinite() && value > 0f) { "speed must be positive and finite" }
    return value
}

internal data class PlaybackConfig(
    val live: Boolean = false,
    val autoPlay: Boolean = false,
    val looping: Boolean = false,
    val volume: Float = 1f,
    val speed: Float = 1f,
    val bufferMinMs: Int = 50_000,
    val bufferMaxMs: Int = 50_000,
    val bufferPlaybackMs: Int = 2_500,
    val bufferRebufferMs: Int = 5_000,
    val liveTargetOffsetMs: Long? = null,
    val enableDecoderFallback: Boolean = true,
    val loopPlaylist: Boolean = false,
) {
    companion object {
        fun parse(raw: Any?): PlaybackConfig {
            if (raw == null) return PlaybackConfig()
            require(raw is Map<*, *>) { "config must be a map" }
            fun boolean(key: String, fallback: Boolean) =
                if (raw.containsKey(key)) raw.requiredBoolean(key) else fallback
            fun number(key: String, fallback: Float) =
                if (raw.containsKey(key)) raw.requiredNumber(key).toFloat() else fallback
            fun millis(key: String, fallback: Int): Int {
                if (!raw.containsKey(key)) return fallback
                val value = raw.requiredNumber(key).toDouble()
                require(value >= 0 && value <= Int.MAX_VALUE && value % 1 == 0.0) {
                    "$key must be a non-negative 32-bit integer"
                }
                return value.toInt()
            }
            val config = PlaybackConfig(
                live = boolean("live", false), autoPlay = boolean("autoPlay", false),
                looping = boolean("looping", false), volume = validVolume(number("volume", 1f)),
                speed = validSpeed(number("speed", 1f)),
                bufferMinMs = millis("bufferMinMs", 50_000),
                bufferMaxMs = millis("bufferMaxMs", 50_000),
                bufferPlaybackMs = millis("bufferPlaybackMs", 2_500),
                bufferRebufferMs = millis("bufferRebufferMs", 5_000),
                liveTargetOffsetMs = raw["liveTargetOffsetMs"]?.let {
                    raw.requiredNonNegativeLong("liveTargetOffsetMs").also { offset ->
                        require(offset <= 60_000) { "liveTargetOffsetMs must be between 0 and 60000" }
                    }
                },
                enableDecoderFallback = boolean("enableDecoderFallback", true),
                loopPlaylist = boolean("loopPlaylist", false),
            )
            require(config.bufferMinMs >= config.bufferPlaybackMs && config.bufferMinMs >= config.bufferRebufferMs) {
                "bufferMinMs must be at least bufferPlaybackMs and bufferRebufferMs"
            }
            require(config.bufferMaxMs >= config.bufferMinMs) { "bufferMaxMs must be at least bufferMinMs" }
            return config
        }
    }
}
