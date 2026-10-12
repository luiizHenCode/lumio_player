# Android backend

Uses AndroidX Media3 ExoPlayer 1.9.2 directly, with either one Flutter
`SurfaceProducer` texture (default) or a native `SurfaceView` per player. No `video_player` dependency. Requires Android API 24+ and a
Flutter embedding exposing `SurfaceProducer.onSurfaceAvailable/onSurfaceCleanup`.

## Channels

- MethodChannel: `lumio_player/methods`
- EventChannel: `lumio_player/events` (one shared stream, routed by player `id`)

`create` accepts optional `{viewType: 'texture' | 'platformView'}`. Omitting the
key defaults to `texture`; explicit null, wrong types, and other values return
`invalid_argument` before allocating a player/producer. Texture mode returns
`{id, textureId}`; platformView mode returns `{id}` and allocates no texture
producer. The rendering mode is fixed for the instance.

For platformView mode, Dart mounts `AndroidView(viewType:
'lumio_player/native_view', creationParams: {'id': id}, creationParamsCodec:
StandardMessageCodec())`. The registered factory validates the ID and rendering
mode. It binds a `SurfaceView` to the instance's existing ExoPlayer, never a
second playback engine. ExoPlayer manages SurfaceHolder creation/destruction;
the holder owns its Surface (the plugin must not release it).

`getPosition` accepts `{id}` and returns an integer position in milliseconds
from the current ExoPlayer, clamped to zero, or zero before a source is opened.
Unknown/disposed IDs and malformed IDs return `invalid_argument`.

`open`, `openPlaylist`, `selectPlaylistItem`,
`play`, `pause`, `seek`, `seekToLive`,
`volume`, `speed`, `looping`, and `dispose` accept an `id`. Mutating methods return null.
`seekToLive` accepts `{id}` and calls `seekToDefaultPosition()` only when Media3
reports `isCurrentMediaItemLive`. Non-live or not-yet-loaded media returns the
MethodChannel error code `unsupported_live_seek`; a caller-supplied `live` flag
alone does not make this operation available.
`diagnostics` accepts an optional `id`: platform/decoder capability information
is always returned, and per-player state/format information is included when an
ID is supplied. Per-player `videoDecoderName` and `audioDecoderName` reflect the
actual initialized decoders reported by Media3 analytics, or null when none is
active. Diagnostics also expose `enableDecoderFallback` and `liveTargetOffsetMs`.
Source URLs and request headers are not exposed in diagnostics.

`open` accepts `source` and an optional `config` map. Sources:

- `network`: HTTP, HTTPS, or RTSP URI. HTTP headers are applied to manifests,
  segments, and progressive requests. Media3 RTSP does not support arbitrary
  HTTP request headers; RTSP authentication uses URI credentials.
- `file`: filesystem path, `file://` URI, or `content://` URI. The host must have
  any required file permissions or content-URI grants.
- `asset`: logical Flutter asset key, resolved via the engine's asset lookup.
  An optional `source.package` supports package assets.

`source.format` defaults to `auto`; explicit values are `hls`, `dash`,
`progressive`, and `rtsp`. Format hints select the Media3 source implementation.
The host controls Android cleartext traffic policy; the plugin adds INTERNET
permission but does not weaken network security settings.

## Native playlists

`openPlaylist` accepts `{id, sources: [sourceMap, ...], index: 0, config: {...}}`.
The list must be nonempty; each item uses exactly the source contract above.
`index` is optional and defaults to zero. Explicit indexes must be non-negative
integers smaller than the queue length. Missing/null/wrong-type selection indexes,
fractional values, overflow, empty queues, and out-of-range indexes return
`invalid_argument`. All sources and configuration are validated/resolved before
replacing the existing player. Each source has its own HTTP/data-source factory,
so headers cannot leak into another item's requests. Assets, format hints, live
target offsets, decoder fallback, and buffering retain the single-open behavior.

The native player receives `setMediaSources(mediaSources, index, 0)` and advances
between items itself, without Dart reopening or recreating the player. `open`
shares this implementation with a one-item queue, index zero.

`selectPlaylistItem` accepts `{id, index}` and seeks the existing queue to that
item at position zero, including reselecting the same item. It preserves
`playWhenReady`: selecting from an ended queue resumes if play intent was true;
paused playback stays paused. Selection after a fatal error prepares the player
again. No new player/texture is created. Both commands return null on success.

Repeat precedence is `config.looping` → repeat ONE, otherwise
`config.loopPlaylist` → repeat ALL, otherwise OFF. The existing `looping` command
updates repeat ONE and restores the configured playlist repeat mode when false.
`completed` means the native queue has ended, not that an intermediate item ended.

Configuration defaults:

| Option | Default |
| --- | --- |
| `live` | false (also detected from the media timeline) |
| `autoPlay` | false |
| `looping` | false |
| `loopPlaylist` | false |
| `volume` | 1.0, valid range 0–1 |
| `speed` | 1.0, finite and positive |
| `bufferMinMs` | 50000 |
| `bufferMaxMs` | 50000 |
| `bufferPlaybackMs` | 2500 |
| `bufferRebufferMs` | 5000 |
| `liveTargetOffsetMs` | null (Media3/source default); optional integer 0–60000 |
| `enableDecoderFallback` | true |

Minimum buffering must be at least both playback thresholds; maximum buffering
must be at least minimum buffering. `live` reports caller intent but does not
force live behavior on VOD or change these defaults. Reopening resets playback
and replaces the ExoPlayer to apply buffer configuration, retaining the texture
ID or rebinding the currently attached native view to the replacement player. Configuration is validated before replacing the existing source.
When supplied, `liveTargetOffsetMs` sets the MediaItem live target offset; actual
live positioning remains subject to the source timeline and Media3 behavior.
`enableDecoderFallback` lets Media3 try lower-priority decoders if the preferred
decoder fails to initialize; it does not guarantee software decoding or recovery
from every decoder failure.

State events contain `id`, `type: state`, `initialized`, `playing`, `buffering`,
`completed`, `positionMs`, `durationMs`, `width`, `height`, `bufferedPositionMs`,
`bufferedRanges`,
`live`, `volume`, `speed`, `playlistIndex` (Media3 `currentMediaItemIndex`), and
`playlistLength` (Media3 `mediaItemCount`). An ordinary `open` reports index 0 and
length 1; before any open, length is 0. An unknown duration is reported as 0; an unknown
video size is 0×0. Initialization means the player has reached READY at least
once for the current item. Item transitions and explicit selections clear the
previous item's initialization/error and update source type/format metadata.
Seamless transitions already in READY initialize the new item in the same event
batch. Position/duration snapshots are emitted after native transitions, with periodic
updates every 500 ms while instances exist. A new event subscription gets a
snapshot of all instances, plus their latest errors.

### First-frame renderer evidence

Every `state` snapshot (including subscription replay and diagnostics `state`)
adds these StandardMessageCodec-safe fields; all existing fields, including
video `width`/`height`, `id`, and `playlistIndex`, are unchanged:

| Field | Type | Value |
| --- | --- | --- |
| `selectionEpoch` | integer (native Long) | 0 initially/on open; caller-supplied epoch on explicit selection |
| `hasRenderedFirstFrame` | boolean | false until the current item's renderer callback is accepted |
| `firstFrameSupported` | boolean | true for this ExoPlayer backend, in texture and platformView modes |
| `firstFrameEvidence` | string, optional | `'renderer'` only when `hasRenderedFirstFrame` is true; omitted when false |

Evidence means **“renderer apresentou frame”**: Media3
`AnalyticsListener.onRenderedFirstFrame` reported rendering to its output. It
is **not** a guarantee of a visible screen or Flutter composition. Neither the
same SurfaceView nor a bound/available texture proves Flutter presented it.
READY, dimensions, surface availability, and decoder initialization alone never
set this flag. Audio-only playback stays false and can become initialized/READY
normally without waiting for a video frame. `firstFrameSupported` describes the
backend capability, not whether the current source contains video.

Successful `open`/`openPlaylist`, explicit selection (even the same index), and
native item transitions reset evidence to false. Invalid requests do not reset
the current source. A first accepted callback emits an immediate `type: 'state'`
snapshot for the same instance `id` and current `playlistIndex`; no separate
`firstFrame` event is sent. Further callbacks do not duplicate that notification.
Listeners are scoped to the exact ExoPlayer and item generation; callbacks from
released/replaced players, prior selections, mismatched event timelines/indexes,
and renderer timestamps strictly before the reset are ignored. A callback from
the current generation rendered in the same millisecond as the reset is accepted;
old-generation listeners remain invalid even with an equal/newer timestamp. Surface remount alone does not
reset historical evidence for the current item.

`selectPlaylistItem` additionally accepts optional `selectionEpoch`: a
non-negative integer within signed 64-bit range. Omission preserves the current
epoch (legacy behavior); explicit null, wrong types, negative/fractional values,
and overflow return `invalid_argument` before resetting evidence or selecting.
The instance updates the epoch before resetting the listener or invoking the
native seek, so synchronous state callbacks already carry the requested epoch.
All `state` snapshots include `selectionEpoch`, including renderer notifications,
periodic updates, replay, and diagnostics. Successful `open`/`openPlaylist` reset
it to 0; automatic item transitions keep it unchanged. Epochs are caller tokens,
not native counters: native code neither increments them nor enforces monotonicity.
Dart can increment its expected epoch per explicit selection, reset it to 0 on
start/open, and reject queued states whose epoch differs, including old same-item
states carrying previous first-frame evidence.

Native code supplies evidence only: no first-frame wait, timeout, readiness gate,
retry, or stage budget is introduced. Dart owns any stage pipeline and budgets.

`bufferedRanges` is a list of `{startMs, endMs}` integer-millisecond maps. Media3
exposes only the current item's forward-buffer endpoint, not arbitrary cached
or disconnected ranges. We report at most one known interval, **currentPosition
through bufferedPosition**, only when a source exists and the endpoint is greater
than a valid non-negative current position. Otherwise the list is empty. We do
not assume buffering starts at zero, retain previous ranges after seeks/item
transitions, or reconstruct invisible ranges. `bufferedPositionMs` remains
unchanged for legacy clients. Live positions use Media3's current-window coordinates.

Playback errors contain `id`, `type: error`, `code`, `message`, `details`, and
`recoverable`, `playlistIndex`, and `playlistLength`. Playback error indexes are
captured from Media3's analytics event window, rather than inferred later from
the current item, and are also included in `details.playlistIndex`. This lets the
parent retain errors per item even after selection clears the current error.
Playback error `details.httpStatus` is the numeric response code of the first
`HttpDataSource.InvalidResponseCodeException` in the identity/cycle-safe cause
chain, or null when absent. It is diagnostic evidence only: extracting it does
not consume pending HLS load evidence or change native classification. Textual
`causeMessage` is not used to infer this field; the public Dart failure report
omits arbitrary cause text while retaining this status and Media3 `errorCode`.
Event subscriptions replay only the current/latest retained error. Diagnostics
expose only error identity/code/recoverability/indexes, not exception text that
could contain URLs or headers. A recoverable classification indicates retry may succeed; there
is no automatic retry loop. Call `open` again to reprepare after a fatal player
error. Invalid method arguments return `invalid_argument` through the method
channel. Unexpected native operation failures also emit an error when an
instance is known.

Flutter may destroy a rendering surface while keeping the texture alive. The
backend clears ExoPlayer's surface on cleanup and binds the new surface on
availability. Flutter owns the Surface; the plugin releases the producer, not
the Surface. Engine detachment stops updates and releases all instances.

For native views, Flutter detach clears only the video output; reattach restores
it if that view still owns the instance. Disposing a PlatformView never disposes,
pauses, or resets the player. The most recently created view owns the output;
late detach/dispose/reattach from superseded views cannot disconnect or reclaim
the new output. Fullscreen remounts must use the same player ID. Once a new view
has superseded an old view, returning inline requires mounting another view
with that ID (the old view cannot reclaim ownership). `open`/`openPlaylist`
rebind the owner to their replacement ExoPlayer, while playlist selections keep
the existing player and output. Method `dispose` invalidates view ownership,
clears output, releases the player and any texture producer. Late view callbacks
then do nothing. Diagnostics include `viewType`; `textureId` and
`handlesCropAndRotation` are null in native-view mode. Native `surfaceAvailable`
means the view is attached, not proof that its holder currently has a Surface.

## Native validation

The example now registers the plugin through Flutter's plugin metadata, and a
full APK build has succeeded. Normal host validation does not need an init script.
From `example/android/`:

```sh
./gradlew :lumio_player:compileDebugKotlin :lumio_player:testDebugUnitTest
```

For standalone validation, the init script supplies the installed Flutter
embedding as compile-only/test dependencies without changing Dart or example
sources. `android/local.properties` must contain `sdk.dir` and `flutter.sdk`.

Use JDK 17 for both the Gradle launcher and daemon. A newer default JDK can
cause Mockito 5.0.0/Byte Buddy instrumentation failures; select JDK 17 using
`JAVA_HOME` and, if necessary, Gradle's `-Dorg.gradle.java.home` option rather
than changing plugin dependencies.

Standalone, from `android/`:

```sh
# Set JAVA_HOME to the literal JDK 17 home installed on your machine.
# Example Homebrew installation on macOS:
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ../example/android/gradlew -Dorg.gradle.java.home=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home -p . -I validation.init.gradle compileDebugKotlin testDebugUnitTest

# Focused mocked first-frame tests (same JDK 17 requirement):
JAVA_HOME=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home ../example/android/gradlew -Dorg.gradle.java.home=/opt/homebrew/opt/openjdk@17/libexec/openjdk.jdk/Contents/Home -p . -I validation.init.gradle testDebugUnitTest --tests 'dev.lumio.lumio_player.FirstFrameEvidenceTest'
```

The optional host init script remains available for validating a host that has
not yet generated Flutter plugin metadata. From `example/android/`:

```sh
./gradlew -I ../../android/host-validation.init.gradle :lumio_player:compileDebugKotlin :lumio_player:testDebugUnitTest
```

Unit tests cover configuration/argument validation, queue parsing/index bounds,
repeat precedence, Media3 queue loading, selection play-intent preservation
(including completed/paused/error-idle states), live-seek gating, and
detached-engine behavior. Additional Mockito tests cover create-mode parsing,
position/range guards, native output ownership across fullscreen replacement,
Flutter detach/remount, player replacement, and late callbacks after disposal.
First-frame Mockito tests additionally cover the exact typed protocol, initial
false state, renderer emission, reopen/source replacement, same-item reselection,
playlist index/timeline transitions, queued/old callbacks, disposal, and READY
without a frame (no playback gate).
Actual decoding, network playback, texture rendering, and surface recreation
require device/emulator integration testing.
