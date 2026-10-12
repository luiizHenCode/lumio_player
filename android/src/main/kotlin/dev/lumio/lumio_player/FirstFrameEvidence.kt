package dev.lumio.lumio_player

import androidx.media3.common.util.UnstableApi
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener

// Application-looper only. Renderer evidence is not proof of Flutter composition.
@UnstableApi
internal class FirstFrameEvidence(
    private val currentPlayer: () -> ExoPlayer,
    private val nowMs: () -> Long,
    private val emitState: () -> Unit,
) {
    private var owner: ExoPlayer? = null
    private var listener: AnalyticsListener? = null
    private var generation = 0L
    var hasRenderedFirstFrame = false
        private set

    fun reset(player: ExoPlayer) {
        clear()
        owner = player
        val epoch = generation
        val startedMs = nowMs()
        val callback = object : AnalyticsListener {
            override fun onRenderedFirstFrame(
                eventTime: AnalyticsListener.EventTime, output: Any, renderTimeMs: Long,
            ) {
                // EventTime can be generated on delivery of an already queued notification.
                // The renderer timestamp also excludes old callbacks after same-item reselection.
                if (epoch != generation || owner !== player || currentPlayer() !== player ||
                    renderTimeMs < startedMs ||
                    eventTime.windowIndex != player.currentMediaItemIndex ||
                    eventTime.timeline != player.currentTimeline || hasRenderedFirstFrame
                ) return
                hasRenderedFirstFrame = true
                emitState()
            }
        }
        listener = callback
        player.addAnalyticsListener(callback)
    }

    fun clear() {
        generation++
        hasRenderedFirstFrame = false
        val previousOwner = owner
        val previousListener = listener
        owner = null
        listener = null
        if (previousOwner != null && previousListener != null) {
            previousOwner.removeAnalyticsListener(previousListener)
        }
    }

    fun stateFields(): Map<String, Any> = buildMap {
        put("hasRenderedFirstFrame", hasRenderedFirstFrame)
        put("firstFrameSupported", true)
        if (hasRenderedFirstFrame) put("firstFrameEvidence", "renderer")
    }
}
