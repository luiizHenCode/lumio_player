package dev.lumio.lumio_player

import androidx.media3.common.C
import androidx.media3.common.util.UnstableApi
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsManifest
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.io.IOException
import java.util.Collections
import java.util.IdentityHashMap

@UnstableApi
internal class HlsLiveSegmentFailure : AnalyticsListener {
    private val pending = mutableMapOf<Long, HttpDataSource.InvalidResponseCodeException>()

    override fun onLoadError(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
        error: IOException,
        wasCanceled: Boolean,
    ) {
        val httpError = causeChain(error)
            .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
            .firstOrNull()
        if (!wasCanceled && mediaLoadData.dataType == C.DATA_TYPE_MEDIA && httpError?.responseCode == 404) {
            pending[loadEventInfo.loadTaskId] = httpError
        } else {
            pending.remove(loadEventInfo.loadTaskId)
        }
    }

    override fun onLoadCompleted(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
    ) {
        // A playlist refresh or another rendition's success must not erase a failing segment.
        pending.remove(loadEventInfo.loadTaskId)
    }

    override fun onLoadCanceled(
        eventTime: AnalyticsListener.EventTime,
        loadEventInfo: LoadEventInfo,
        mediaLoadData: MediaLoadData,
    ) {
        pending.remove(loadEventInfo.loadTaskId)
    }

    fun consume(error: Throwable, manifest: Any?, isLive: Boolean, initialized: Boolean): Boolean {
        val matches = initialized && isLive && manifest is HlsManifest &&
            causeChain(error).any { cause -> pending.values.any { it === cause } }
        clear()
        return matches
    }

    fun clear() {
        pending.clear()
    }

    // Diagnostic evidence only: independent of load type/live classification.
    fun httpStatus(error: Throwable): Int? = causeChain(error)
        .filterIsInstance<HttpDataSource.InvalidResponseCodeException>()
        .firstOrNull()?.responseCode

    private fun causeChain(error: Throwable): Sequence<Throwable> = sequence {
        val visited = Collections.newSetFromMap(IdentityHashMap<Throwable, Boolean>())
        var current: Throwable? = error
        while (current != null && visited.add(current)) {
            yield(current)
            current = current.cause
        }
    }
}
