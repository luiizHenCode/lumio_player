package dev.lumio.lumio_player

import androidx.media3.common.C
import androidx.media3.common.PlaybackException
import androidx.media3.common.Timeline
import androidx.media3.datasource.DataSpec
import androidx.media3.datasource.HttpDataSource
import androidx.media3.exoplayer.analytics.AnalyticsListener
import androidx.media3.exoplayer.hls.HlsManifest
import androidx.media3.exoplayer.source.LoadEventInfo
import androidx.media3.exoplayer.source.MediaLoadData
import java.io.IOException
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertNull
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class HlsLiveSegmentFailureTest {
    private val eventTime = AnalyticsListener.EventTime(
        0L, Timeline.EMPTY, 0, null, 0L, Timeline.EMPTY, 0, null, 0L, 0L,
    )
    private val dataSpec = Mockito.mock(DataSpec::class.java)
    private val manifest = Mockito.mock(HlsManifest::class.java)
    private val media = MediaLoadData(C.DATA_TYPE_MEDIA)

    private fun load(id: Long = 1L) = LoadEventInfo(id, dataSpec, 0L)
    private fun http(status: Int = 404) = HttpDataSource.InvalidResponseCodeException(
        status, "HTTP failure", null, emptyMap(), dataSpec, byteArrayOf(),
    )
    private fun playback(cause: Throwable) = Mockito.mockStatic(android.os.SystemClock::class.java).use {
        PlaybackException("Playback failed", cause, PlaybackException.ERROR_CODE_IO_BAD_HTTP_STATUS)
    }
    private fun record(
        tracker: HlsLiveSegmentFailure,
        error: IOException,
        id: Long = 1L,
        data: MediaLoadData = media,
        canceled: Boolean = false,
    ) = tracker.onLoadError(eventTime, load(id), data, error, canceled)

    @Test
    fun matchesTheExactHttpExceptionThroughWrappedCausesOnlyOnce() {
        val tracker = HlsLiveSegmentFailure()
        val error = http()
        record(tracker, IOException("Load failed", error))
        assertTrue(tracker.consume(playback(IOException("Source failed", error)), manifest, true, true))
        assertFalse(tracker.consume(playback(error), manifest, true, true))
    }

    @Test
    fun unrelated404AndTextOrStackImpersonationDoNotMatch() {
        val tracker = HlsLiveSegmentFailure()
        record(tracker, http())
        assertFalse(tracker.consume(playback(http()), manifest, true, true))
        val error = IOException("404 HlsMediaChunk https://private.invalid/segment.ts")
        error.stackTrace = arrayOf(StackTraceElement("HlsMediaChunk", "load", "HlsMediaChunk.java", 404))
        record(tracker, error)
        assertFalse(tracker.consume(playback(error), manifest, true, true))
    }

    @Test
    fun manifestKeysAndOtherNonMediaLoadsAreExcluded() {
        listOf(C.DATA_TYPE_MANIFEST, C.DATA_TYPE_DRM, C.DATA_TYPE_UNKNOWN, C.DATA_TYPE_TIME_SYNCHRONIZATION).forEach { type ->
            val tracker = HlsLiveSegmentFailure()
            val error = http()
            record(tracker, error, data = MediaLoadData(type))
            assertFalse(tracker.consume(playback(error), manifest, true, true), "dataType=$type")
        }
    }

    @Test
    fun authAndOtherHttpStatusesAreExcluded() {
        listOf(401, 403, 410, 500, 503).forEach { status ->
            val tracker = HlsLiveSegmentFailure()
            val error = http(status)
            record(tracker, error)
            assertFalse(tracker.consume(playback(error), manifest, true, true), "status=$status")
        }
    }

    @Test
    fun requiresDetectedHlsLiveAndInitializedPlayback() {
        listOf(
            Triple(null, true, true),
            Triple(Any(), true, true),
            Triple(manifest, false, true),
            Triple(manifest, true, false),
        ).forEach { (currentManifest, live, initialized) ->
            val tracker = HlsLiveSegmentFailure()
            val error = http()
            record(tracker, error)
            assertFalse(tracker.consume(playback(error), currentManifest, live, initialized))
            assertFalse(tracker.consume(playback(error), manifest, true, true))
        }
    }

    @Test
    fun successfulRetryClearsOnlyItsOwnLoadNotPlaylistOrOtherRendition() {
        val tracker = HlsLiveSegmentFailure()
        val error = http()
        record(tracker, error)
        tracker.onLoadCompleted(eventTime, load(2L), MediaLoadData(C.DATA_TYPE_MANIFEST))
        tracker.onLoadCompleted(eventTime, load(3L), media)
        assertTrue(tracker.consume(playback(error), manifest, true, true))
        record(tracker, error)
        tracker.onLoadCompleted(eventTime, load(), media)
        assertFalse(tracker.consume(playback(error), manifest, true, true))
    }

    @Test
    fun sourceResetOrDisposeClearsPendingIdentity() {
        val tracker = HlsLiveSegmentFailure()
        val error = http()
        record(tracker, error)
        tracker.clear()
        assertFalse(tracker.consume(playback(error), manifest, true, true))
    }

    @Test
    fun canceledLoadAndReplacementFailureClearPendingIdentity() {
        val tracker = HlsLiveSegmentFailure()
        val error = http()
        record(tracker, error, canceled = true)
        assertFalse(tracker.consume(playback(error), manifest, true, true))
        record(tracker, error)
        tracker.onLoadCanceled(eventTime, load(), media)
        assertFalse(tracker.consume(playback(error), manifest, true, true))
        record(tracker, error)
        record(tracker, http(403))
        assertFalse(tracker.consume(playback(error), manifest, true, true))
    }

    @Test
    fun concurrentAudioAndVideoFailuresPreserveBothIdentities() {
        val tracker = HlsLiveSegmentFailure()
        val audioError = http()
        val videoError = http()
        record(tracker, audioError, id = 1L)
        record(tracker, videoError, id = 2L)
        tracker.onLoadCompleted(eventTime, load(2L), media)
        assertTrue(tracker.consume(playback(audioError), manifest, true, true))
    }

    @Test
    fun diagnosticHttpStatusUsesTypedCausesAndDoesNotConsumeClassification() {
        val tracker = HlsLiveSegmentFailure()
        listOf(401, 403, 404, 500, 503).forEach { status ->
            assertEquals(status, tracker.httpStatus(playback(IOException("secret URL", http(status)))))
        }
        val error = http()
        record(tracker, error)
        assertEquals(404, tracker.httpStatus(playback(error)))
        assertTrue(tracker.consume(playback(error), manifest, true, true))
        assertEquals(404, tracker.httpStatus(error))
        assertNull(tracker.httpStatus(IOException("Response code: 404 password=secret")))
    }

    @Test
    fun diagnosticHttpStatusTerminatesOnCyclesWithAndWithoutTypedHttpCause() {
        val tracker = HlsLiveSegmentFailure()
        val first = IOException("Response code: 404")
        val second = IOException("secret", first)
        first.initCause(second)
        assertNull(tracker.httpStatus(first))
        val httpError = Mockito.spy(http(403))
        val wrapper = IOException("secret", httpError)
        Mockito.`when`(httpError.cause).thenReturn(wrapper)
        assertEquals(403, tracker.httpStatus(wrapper))
    }

    @Test
    fun cyclicCauseChainTerminatesWithoutClassifyingText() {
        val tracker = HlsLiveSegmentFailure()
        val first = IOException("404")
        val second = IOException("HlsMediaChunk", first)
        first.initCause(second)
        record(tracker, first)
        assertFalse(tracker.consume(playback(first), manifest, true, true))
    }
}
