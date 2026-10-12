package dev.lumio.lumio_player

import android.content.Context
import android.view.SurfaceView
import android.view.View
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import io.flutter.plugin.platform.PlatformView

internal enum class PlayerViewType { texture, platformView }

internal fun parseViewType(args: Map<*, *>): PlayerViewType {
    if (!args.containsKey("viewType")) return PlayerViewType.texture
    return when (args["viewType"]) {
        "texture" -> PlayerViewType.texture
        "platformView" -> PlayerViewType.platformView
        else -> throw IllegalArgumentException("viewType must be texture or platformView")
    }
}

internal fun playerPosition(player: Player, hasSource: Boolean): Long =
    if (hasSource) player.currentPosition.coerceAtLeast(0L) else 0L

internal fun knownBufferedRanges(player: Player, hasSource: Boolean): List<Map<String, Long>> {
    if (!hasSource) return emptyList()
    val start = player.currentPosition
    val end = player.bufferedPosition
    // Media3 exposes the current forward buffer endpoint, not all cached ranges.
    if (start < 0 || end == C.TIME_UNSET || end <= start) return emptyList()
    return listOf(mapOf("startMs" to start, "endMs" to end))
}

// Application-looper only. ExoPlayer owns the SurfaceHolder callbacks, not its Surface.
// A newer view permanently supersedes the old owner, including late detach/dispose calls.
@UnstableApi
internal class NativeSurfaceBinding(private val player: () -> ExoPlayer) {
    private var owner: SurfaceView? = null
    private var closed = false
    var attached = false
        private set

    fun claim(view: SurfaceView) {
        if (closed) return
        owner?.let { detach(it) }
        owner = view
        attach(view)
    }

    fun attach(view: SurfaceView) {
        if (closed || owner !== view || attached) return
        player().setVideoSurfaceView(view)
        attached = true
    }

    fun detach(view: SurfaceView) {
        if (closed || owner !== view || !attached) return
        player().clearVideoSurfaceView(view)
        attached = false
    }

    fun release(view: SurfaceView) {
        if (owner !== view) return
        detach(view)
        owner = null
    }

    fun rebind() {
        if (!closed && attached) owner?.let { player().setVideoSurfaceView(it) }
    }

    fun close() {
        if (closed) return
        try {
            owner?.let { detach(it) }
        } finally {
            closed = true
            attached = false
            owner = null
        }
    }
}

@UnstableApi
internal class NativePlayerView(context: Context, private val binding: NativeSurfaceBinding) : PlatformView {
    private val surfaceView = SurfaceView(context)
    private var disposed = false

    init { binding.claim(surfaceView) }

    override fun getView(): View = surfaceView

    override fun onFlutterViewAttached(flutterView: View) {
        if (!disposed) binding.attach(surfaceView)
    }

    override fun onFlutterViewDetached() {
        binding.detach(surfaceView)
    }

    override fun dispose() {
        if (disposed) return
        disposed = true
        binding.release(surfaceView)
    }
}
