# Android backend

Uses AndroidX Media3 ExoPlayer 1.9.2 directly, with one Flutter `SurfaceProducer`
texture per player. No `video_player` dependency. Requires Android API 24+ and a
Flutter embedding exposing `SurfaceProducer.onSurfaceAvailable/onSurfaceCleanup`.

## Channels

- MethodChannel: `lumio_player/methods`
- EventChannel: `lumio_player/events` (one shared stream, routed by player `id`)

`create` returns `{id, textureId}`. `open`, `openPlaylist`, `selectPlaylistItem`,
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
ID. Configuration is validated before replacing the existing source.
When supplied, `liveTargetOffsetMs` sets the MediaItem live target offset; actual
live positioning remains subject to the source timeline and Media3 behavior.
`enableDecoderFallback` lets Media3 try lower-priority decoders if the preferred
decoder fails to initialize; it does not guarantee software decoding or recovery
from every decoder failure.

State events contain `id`, `type: state`, `initialized`, `playing`, `buffering`,
`completed`, `positionMs`, `durationMs`, `width`, `height`, `bufferedPositionMs`,
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

Playback errors contain `id`, `type: error`, `code`, `message`, `details`, and
`recoverable`, `playlistIndex`, and `playlistLength`. Playback error indexes are
captured from Media3's analytics event window, rather than inferred later from
the current item, and are also included in `details.playlistIndex`. This lets the
parent retain errors per item even after selection clears the current error.
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

Standalone, from `android/`:

```sh
../example/android/gradlew -p . -I validation.init.gradle compileDebugKotlin testDebugUnitTest
```

The optional host init script remains available for validating a host that has
not yet generated Flutter plugin metadata. From `example/android/`:

```sh
./gradlew -I ../../android/host-validation.init.gradle :lumio_player:compileDebugKotlin :lumio_player:testDebugUnitTest
```

Unit tests cover configuration/argument validation, queue parsing/index bounds,
repeat precedence, Media3 queue loading, selection play-intent preservation
(including completed/paused/error-idle states), live-seek gating, and
detached-engine behavior.
Actual decoding, network playback, texture rendering, and surface recreation
require device/emulator integration testing.
