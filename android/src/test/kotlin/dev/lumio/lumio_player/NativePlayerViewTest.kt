package dev.lumio.lumio_player

import android.view.SurfaceView
import androidx.media3.common.C
import androidx.media3.common.Player
import androidx.media3.exoplayer.ExoPlayer
import org.mockito.Mockito
import kotlin.test.Test
import kotlin.test.assertEquals
import kotlin.test.assertFailsWith
import kotlin.test.assertFalse
import kotlin.test.assertTrue

internal class NativePlayerViewTest {
    private fun player(): ExoPlayer = Mockito.mockStatic(androidx.media3.common.util.Util::class.java).use {
        Mockito.mock(ExoPlayer::class.java)
    }

    @Test
    fun createDefaultsToTextureAndAcceptsOnlyTheTwoModes() {
        assertEquals(PlayerViewType.texture, parseViewType(emptyMap<Any, Any>()))
        assertEquals(PlayerViewType.texture, parseViewType(mapOf("viewType" to "texture")))
        assertEquals(PlayerViewType.platformView, parseViewType(mapOf("viewType" to "platformView")))
        listOf(null, "", "Texture", "surface", 1, true).forEach {
            assertFailsWith<IllegalArgumentException> { parseViewType(mapOf("viewType" to it)) }
        }
    }

    @Test
    fun invalidCreateModeReturnsChannelErrorBeforeAllocatingNativeResources() {
        val plugin = LumioPlayerPlugin()
        val engine = Mockito.mock(io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding::class.java)
        LumioPlayerPlugin::class.java.getDeclaredField("binding").apply { isAccessible = true }.set(plugin, engine)
        val result = Mockito.mock(io.flutter.plugin.common.MethodChannel.Result::class.java)
        plugin.onMethodCall(io.flutter.plugin.common.MethodCall("create", mapOf("viewType" to "invalid")), result)
        Mockito.verify(result).error("invalid_argument", "viewType must be texture or platformView", null)
        Mockito.verifyNoInteractions(engine)
    }

    @Test
    fun getPositionRejectsUnknownOrMalformedIdsThroughTheChannel() {
        val plugin = LumioPlayerPlugin()
        val engine = Mockito.mock(io.flutter.embedding.engine.plugins.FlutterPlugin.FlutterPluginBinding::class.java)
        LumioPlayerPlugin::class.java.getDeclaredField("binding").apply { isAccessible = true }.set(plugin, engine)
        listOf(emptyMap<String, Any>(), mapOf("id" to -1), mapOf("id" to 1.5), mapOf("id" to 99)).forEach { args ->
            val result = Mockito.mock(io.flutter.plugin.common.MethodChannel.Result::class.java)
            plugin.onMethodCall(io.flutter.plugin.common.MethodCall("getPosition", args), result)
            Mockito.verify(result).error(Mockito.eq("invalid_argument"), Mockito.anyString(), Mockito.isNull())
            Mockito.verifyNoMoreInteractions(result)
        }
    }

    @Test
    fun positionIsCurrentNonNegativeAndDoesNotReadPlayerWithoutSource() {
        val player = Mockito.mock(Player::class.java)
        assertEquals(0L, playerPosition(player, false))
        Mockito.verifyNoInteractions(player)
        listOf(1234L to 1234L, 0L to 0L, -1L to 0L, C.TIME_UNSET to 0L).forEach { (native, expected) ->
            Mockito.`when`(player.currentPosition).thenReturn(native)
            assertEquals(expected, playerPosition(player, true))
        }
    }

    @Test
    fun rangesExposeOnlyTheKnownForwardIntervalAndDoNotRetainEarlierRanges() {
        val player = Mockito.mock(Player::class.java)
        assertEquals(emptyList(), knownBufferedRanges(player, false))
        Mockito.verifyNoInteractions(player)
        Mockito.`when`(player.currentPosition).thenReturn(5000L)
        Mockito.`when`(player.bufferedPosition).thenReturn(8000L)
        assertEquals(listOf(mapOf("startMs" to 5000L, "endMs" to 8000L)), knownBufferedRanges(player, true))
        Mockito.`when`(player.currentPosition).thenReturn(6000L)
        assertEquals(listOf(mapOf("startMs" to 6000L, "endMs" to 8000L)), knownBufferedRanges(player, true))
        listOf(6000L, 100L, -1L, C.TIME_UNSET).forEach {
            Mockito.`when`(player.bufferedPosition).thenReturn(it)
            assertTrue(knownBufferedRanges(player, true).isEmpty())
        }
        Mockito.`when`(player.currentPosition).thenReturn(C.TIME_UNSET)
        Mockito.`when`(player.bufferedPosition).thenReturn(8000L)
        assertTrue(knownBufferedRanges(player, true).isEmpty())
    }

    @Test
    fun fullscreenReplacementRejectsOldDetachDisposeAndReattach() {
        val player = player()
        val binding = NativeSurfaceBinding { player }
        val inline = Mockito.mock(SurfaceView::class.java)
        val fullscreen = Mockito.mock(SurfaceView::class.java)
        binding.claim(inline)
        binding.claim(fullscreen)
        val order = Mockito.inOrder(player)
        order.verify(player).setVideoSurfaceView(inline)
        order.verify(player).clearVideoSurfaceView(inline)
        order.verify(player).setVideoSurfaceView(fullscreen)
        Mockito.clearInvocations(player)
        binding.detach(inline)
        binding.release(inline)
        binding.attach(inline)
        assertTrue(binding.attached)
        Mockito.verifyNoInteractions(player)
        binding.release(fullscreen)
        assertFalse(binding.attached)
        Mockito.verify(player).clearVideoSurfaceView(fullscreen)
        Mockito.verify(player, Mockito.never()).release()
    }

    @Test
    fun detachRemountAndReopenUseCurrentPlayerAndPreserveOwner() {
        val original = player()
        val replacement = player()
        var current = original
        val binding = NativeSurfaceBinding { current }
        val view = Mockito.mock(SurfaceView::class.java)
        binding.claim(view)
        binding.detach(view)
        binding.detach(view)
        Mockito.verify(original).clearVideoSurfaceView(view)
        current = replacement
        binding.rebind()
        Mockito.verifyNoInteractions(replacement)
        binding.attach(view)
        binding.attach(view)
        Mockito.verify(replacement).setVideoSurfaceView(view)
        Mockito.clearInvocations(replacement)
        current = original
        binding.rebind()
        Mockito.verify(original, Mockito.times(2)).setVideoSurfaceView(view)
        binding.release(view)
        binding.attach(view)
        assertFalse(binding.attached)
        Mockito.verifyNoInteractions(replacement)
    }

    @Test
    fun playerDisposeMakesLateViewCallbacksHarmlessAndDoesNotReleaseHolderSurface() {
        val player = player()
        val binding = NativeSurfaceBinding { player }
        val view = Mockito.mock(SurfaceView::class.java)
        binding.claim(view)
        binding.close()
        Mockito.verify(player).clearVideoSurfaceView(view)
        Mockito.clearInvocations(player, view)
        binding.close()
        binding.attach(view)
        binding.detach(view)
        binding.release(view)
        binding.claim(view)
        binding.rebind()
        assertFalse(binding.attached)
        Mockito.verifyNoInteractions(player, view)
    }
}
