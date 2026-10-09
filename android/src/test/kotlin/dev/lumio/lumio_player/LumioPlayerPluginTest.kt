package dev.lumio.lumio_player

import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import androidx.media3.exoplayer.source.MediaSource
import io.flutter.plugin.common.MethodCall
import io.flutter.plugin.common.MethodChannel
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertNull
import kotlin.test.assertTrue

internal class LumioPlayerPluginTest {
    @Test
    fun detachedEngineRejectsCalls() {
        val plugin = LumioPlayerPlugin()
        val result = Mockito.mock(MethodChannel.Result::class.java)
        plugin.onMethodCall(MethodCall("create", null), result)
        Mockito.verify(result).error("engine_detached", "The Flutter engine is not attached", null)
    }

    @Test
    fun defaultsAreValid() {
        val config = PlaybackConfig.parse(null)
        assertFalse(config.autoPlay)
        assertEquals(1f, config.volume)
        assertEquals(1f, config.speed)
        assertEquals(50_000, config.bufferMinMs)
        assertNull(config.liveTargetOffsetMs)
        assertTrue(config.enableDecoderFallback)
    }

    @Test
    fun acceptsLiveBufferConfigurationAndChannelNumberTypes() {
        val config = PlaybackConfig.parse(mapOf(
            "live" to true, "autoPlay" to true, "looping" to true,
            "volume" to 0.5, "speed" to 2,
            "bufferMinMs" to 1_000L, "bufferMaxMs" to 3_000,
            "bufferPlaybackMs" to 250, "bufferRebufferMs" to 500,
        ))
        assertEquals(PlaybackConfig(true, true, true, 0.5f, 2f, 1_000, 3_000, 250, 500), config)
    }

    @Test
    fun acceptsOptionalLiveTargetOffsetAndDecoderFallback() {
        listOf<Number>(0, 30_000L, 60_000).forEach { offset ->
            val config = PlaybackConfig.parse(mapOf(
                "liveTargetOffsetMs" to offset, "enableDecoderFallback" to false,
            ))
            assertEquals(offset.toLong(), config.liveTargetOffsetMs)
            assertFalse(config.enableDecoderFallback)
        }
        assertNull(PlaybackConfig.parse(mapOf("liveTargetOffsetMs" to null)).liveTargetOffsetMs)
    }

    @Test
    fun rejectsInvalidLiveTargetOffsetsAndDecoderFallback() {
        listOf(-1, 60_001, 1.5, Double.NaN, Double.POSITIVE_INFINITY, Long.MAX_VALUE, "1000").forEach {
            assertFailsWith<IllegalArgumentException> {
                PlaybackConfig.parse(mapOf("liveTargetOffsetMs" to it))
            }
        }
        listOf(0, "true", null).forEach {
            assertFailsWith<IllegalArgumentException> {
                PlaybackConfig.parse(mapOf("enableDecoderFallback" to it))
            }
        }
    }

    @Test
    fun seekToLiveUsesDefaultPositionForLiveMedia() {
        val player = Mockito.mock(Player::class.java)
        Mockito.`when`(player.isCurrentMediaItemLive).thenReturn(true)
        assertTrue(player.seekToLive())
        Mockito.verify(player).seekToDefaultPosition()
    }

    @Test
    fun seekToLiveRejectsNonLiveOrUninitializedMedia() {
        val player = Mockito.mock(Player::class.java)
        Mockito.`when`(player.isCurrentMediaItemLive).thenReturn(false)
        assertFalse(player.seekToLive())
        Mockito.verify(player, Mockito.never()).seekToDefaultPosition()
    }

    @Test
    fun rejectsInvalidBufferDurations() {
        listOf(
            mapOf("bufferMinMs" to -1),
            mapOf("bufferMinMs" to 1.5),
            mapOf("bufferMaxMs" to 1),
            mapOf("bufferPlaybackMs" to 60_000),
            mapOf("bufferRebufferMs" to 60_000),
            mapOf("bufferMaxMs" to Long.MAX_VALUE),
        ).forEach { assertFailsWith<IllegalArgumentException> { PlaybackConfig.parse(it) } }
    }

    @Test
    fun validatesIntegerIdsAndSeekPositions() {
        assertEquals(42L, mapOf("id" to 42).requiredNonNegativeLong("id"))
        assertEquals(Long.MAX_VALUE, mapOf("id" to Long.MAX_VALUE).requiredNonNegativeLong("id"))
        listOf(-1, 1.5, Double.NaN, Double.POSITIVE_INFINITY, 1e30).forEach {
            assertFailsWith<IllegalArgumentException> { mapOf("id" to it).requiredNonNegativeLong("id") }
        }
        assertFailsWith<IllegalArgumentException> { emptyMap<String, Any>().requiredNonNegativeLong("id") }
    }

    @Test
    fun parsesQueueAndSingleOpenThroughTheSameContract() {
        val first = mapOf("type" to "network", "uri" to "https://example.test/a")
        val second = mapOf("type" to "asset", "uri" to "video.mp4")
        val args = mapOf("sources" to listOf(first, second))
        assertEquals(QueueRequest(listOf(first, second), 0), QueueRequest.parse(args, true))
        assertEquals(1, QueueRequest.parse(args + ("index" to 1L), true).index)
        assertEquals(QueueRequest(listOf(first), 0), QueueRequest.parse(mapOf("source" to first), false))
        listOf(
            emptyMap<String, Any>(), mapOf("sources" to "bad"),
            mapOf("sources" to emptyList<Any>()), mapOf("sources" to listOf(first, null)),
        ).forEach { assertFailsWith<IllegalArgumentException> { QueueRequest.parse(it, true) } }
    }

    @Test
    fun validatesQueueIndexesWithoutTruncationOrOverflow() {
        assertEquals(0, mapOf("index" to 0).playlistIndex(1))
        assertEquals(1, mapOf("index" to 1L).playlistIndex(2))
        listOf(null, -1, 2, 1.5, Double.NaN, Double.POSITIVE_INFINITY, Long.MAX_VALUE, "1").forEach {
            assertFailsWith<IllegalArgumentException> { mapOf("index" to it).playlistIndex(2) }
            assertFailsWith<IllegalArgumentException> {
                QueueRequest.parse(mapOf("sources" to listOf(emptyMap<String, Any>(), emptyMap<String, Any>()), "index" to it), true)
            }
        }
        assertFailsWith<IllegalArgumentException> { mapOf("index" to 0).playlistIndex(0) }
    }

    @Test
    fun playlistRepeatPrecedenceAndValidation() {
        assertEquals(Player.REPEAT_MODE_OFF, playlistRepeatMode(false, false))
        assertEquals(Player.REPEAT_MODE_ALL, playlistRepeatMode(false, true))
        assertEquals(Player.REPEAT_MODE_ONE, playlistRepeatMode(true, false))
        assertEquals(Player.REPEAT_MODE_ONE, playlistRepeatMode(true, true))
        assertFalse(PlaybackConfig.parse(null).loopPlaylist)
        assertTrue(PlaybackConfig.parse(mapOf("loopPlaylist" to true)).loopPlaylist)
        listOf(null, 1, "true").forEach {
            assertFailsWith<IllegalArgumentException> { PlaybackConfig.parse(mapOf("loopPlaylist" to it)) }
        }
    }

    @Test
    fun loadsActualMedia3QueueAtRequestedIndexAndZeroPosition() {
        // ExoPlayer's interface initializer checks device metadata absent in JVM Android stubs.
        Mockito.mockStatic(androidx.media3.common.util.Util::class.java).use {
            val player = Mockito.mock(ExoPlayer::class.java)
            val sources = List(2) { Mockito.mock(MediaSource::class.java) }
            player.loadPlaylist(sources, 1, true)
            Mockito.verify(player).setMediaSources(sources, 1, 0L)
            Mockito.verify(player).playWhenReady = true
            Mockito.verify(player).prepare()
            assertFailsWith<IllegalArgumentException> { player.loadPlaylist(sources, 2, false) }
            assertFailsWith<IllegalArgumentException> { player.loadPlaylist(emptyList(), 0, false) }
        }
    }

    @Test
    fun selectionPreservesPlayIntentIncludingCompletedAndPausedItems() {
        listOf(Player.STATE_READY, Player.STATE_ENDED, Player.STATE_IDLE).forEach { state ->
            listOf(false, true).forEach { shouldPlay ->
                val player = Mockito.mock(Player::class.java)
                Mockito.`when`(player.mediaItemCount).thenReturn(2)
                Mockito.`when`(player.playWhenReady).thenReturn(shouldPlay)
                Mockito.`when`(player.playbackState).thenReturn(state)
                player.selectPlaylistItem(1)
                Mockito.verify(player).seekTo(1, 0L)
                Mockito.verify(player).playWhenReady = shouldPlay
                Mockito.verify(player, Mockito.times(if (state == Player.STATE_IDLE) 1 else 0)).prepare()
            }
        }
    }

    @Test
    fun invalidSelectionDoesNotTouchPlayback() {
        val player = Mockito.mock(Player::class.java)
        Mockito.`when`(player.mediaItemCount).thenReturn(2)
        listOf(-1, 2, Int.MAX_VALUE).forEach {
            assertFailsWith<IllegalArgumentException> { player.selectPlaylistItem(it) }
        }
        Mockito.verify(player, Mockito.never()).seekTo(Mockito.anyInt(), Mockito.anyLong())
        Mockito.verify(player, Mockito.never()).prepare()
        Mockito.verify(player, Mockito.never()).playWhenReady = Mockito.anyBoolean()
    }

    @Test
    fun rejectsMalformedOptions() {
        listOf(
            mapOf("volume" to Double.NaN), mapOf("volume" to 1.1),
            mapOf("volume" to -0.1), mapOf("speed" to 0),
            mapOf("speed" to Double.POSITIVE_INFINITY), mapOf("speed" to "fast"),
            mapOf("looping" to 1), mapOf("live" to "true"),
        ).forEach { assertFailsWith<IllegalArgumentException> { PlaybackConfig.parse(it) } }
        assertFailsWith<IllegalArgumentException> { PlaybackConfig.parse("invalid") }
    }
}
