package dev.lumio.lumio_player

import androidx.media3.common.C
import androidx.media3.common.Tracks
import androidx.media3.common.Player
import androidx.media3.common.Timeline
import androidx.media3.common.util.Util
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.analytics.AnalyticsListener
import org.mockito.ArgumentCaptor
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class FirstFrameEvidenceTest {
    private class Fixture {
        fun mockPlayer(): ExoPlayer {
            val player = Mockito.mockStatic(Util::class.java).use {
                Mockito.mock(ExoPlayer::class.java)
            }
            val timeline = Timeline.EMPTY
            Mockito.`when`(player.currentTimeline).thenReturn(timeline)
            return player
        }
        var player = mockPlayer()
        var time = 100L
        val snapshots = mutableListOf<Map<String, Any>>()
        val evidence: FirstFrameEvidence = FirstFrameEvidence({ player }, { time }, { snapshots += evidenceFields() })
        private fun evidenceFields(): Map<String, Any> = evidence.stateFields()

        fun reset(): AnalyticsListener {
            evidence.reset(player)
            val captor = ArgumentCaptor.forClass(AnalyticsListener::class.java)
            Mockito.verify(player, Mockito.atLeastOnce()).addAnalyticsListener(captor.capture())
            return captor.value
        }

        fun frame(
            listener: AnalyticsListener, timestamp: Long = time + 1,
            index: Int = player.currentMediaItemIndex, timeline: Timeline = player.currentTimeline,
        ) {
            val event = AnalyticsListener.EventTime(
                time, timeline, index, null, 0L, timeline, index, null, 0L, 0L,
            )
            listener.onRenderedFirstFrame(event, Any(), timestamp)
        }
    }

    @Test
    fun protocolIsTypedAndOnlyRendererCallbackEmitsEvidenceOnce() {
        val f = Fixture()
        assertEquals(mapOf("hasRenderedFirstFrame" to false, "firstFrameSupported" to true), f.evidence.stateFields())
        val callback = f.reset()
        f.frame(callback)
        assertEquals(listOf(mapOf<String, Any>(
            "hasRenderedFirstFrame" to true, "firstFrameSupported" to true, "firstFrameEvidence" to "renderer",
        )), f.snapshots)
        f.frame(callback)
        assertEquals(1, f.snapshots.size)
    }

    @Test
    fun reopenResetsEvidenceAndRejectsOldPlayerEvenBeforeListenerRemoval() {
        val f = Fixture()
        val oldPlayer = f.player
        val old = f.reset()
        f.frame(old)
        f.player = f.mockPlayer()
        f.frame(old)
        assertEquals(1, f.snapshots.size)
        f.time = 200L
        val current = f.reset()
        assertFalse(f.evidence.hasRenderedFirstFrame)
        assertFalse(f.evidence.stateFields().containsKey("firstFrameEvidence"))
        Mockito.verify(oldPlayer).removeAnalyticsListener(old)
        f.frame(old, timestamp = 201L)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        f.frame(current)
        assertTrue(f.evidence.hasRenderedFirstFrame)
    }

    @Test
    fun callbackCannotEmitForDifferentCurrentPlayerIdentity() {
        val f = Fixture()
        val callback = f.reset()
        f.player = f.mockPlayer()
        f.frame(callback)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        assertTrue(f.snapshots.isEmpty())
    }

    @Test
    fun sameItemSelectionResetsAndRejectsOldGenerationAndQueuedRendererTimestamp() {
        val f = Fixture()
        val old = f.reset()
        f.frame(old)
        f.time = 200L
        val current = f.reset()
        f.frame(old, timestamp = 200L)
        f.frame(old, timestamp = 201L)
        f.frame(current, timestamp = 199L)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        assertEquals(1, f.snapshots.size)
        f.frame(current, timestamp = 200L)
        assertTrue(f.evidence.hasRenderedFirstFrame)
        assertEquals(2, f.snapshots.size)
        f.frame(current)
        assertEquals(2, f.snapshots.size)
    }

    @Test
    fun playlistTransitionRejectsOldItemAndTimeline() {
        val f = Fixture()
        val old = f.reset()
        f.frame(old)
        Mockito.`when`(f.player.currentMediaItemIndex).thenReturn(1)
        val timeline = Mockito.mock(Timeline::class.java)
        Mockito.`when`(f.player.currentTimeline).thenReturn(timeline)
        f.time = 200L
        val current = f.reset()
        f.frame(old)
        f.frame(current, index = 0)
        f.frame(current, timeline = Timeline.EMPTY)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        f.frame(current)
        assertTrue(f.evidence.hasRenderedFirstFrame)
    }

    @Test
    fun audioOnlyReadyWithoutFrameDoesNotWaitOrMutatePlayback() {
        val f = Fixture()
        val tracks = Mockito.mock(Tracks::class.java)
        Mockito.`when`(tracks.isTypeSelected(C.TRACK_TYPE_AUDIO)).thenReturn(true)
        Mockito.`when`(tracks.isTypeSelected(C.TRACK_TYPE_VIDEO)).thenReturn(false)
        Mockito.`when`(f.player.currentTracks).thenReturn(tracks)
        Mockito.`when`(f.player.playbackState).thenReturn(Player.STATE_READY)
        f.reset()
        assertEquals(Player.STATE_READY, f.player.playbackState)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        assertTrue(f.snapshots.isEmpty())
        Mockito.verify(f.player, Mockito.never()).prepare()
        Mockito.verify(f.player, Mockito.never()).pause()
        Mockito.verify(f.player, Mockito.never()).play()
        Mockito.verify(f.player, Mockito.never()).seekTo(Mockito.anyLong())
    }

    @Test
    fun disposeInvalidatesLateRendererCallback() {
        val f = Fixture()
        val callback = f.reset()
        f.evidence.clear()
        f.frame(callback)
        assertFalse(f.evidence.hasRenderedFirstFrame)
        assertTrue(f.snapshots.isEmpty())
        Mockito.verify(f.player).removeAnalyticsListener(callback)
    }
}
