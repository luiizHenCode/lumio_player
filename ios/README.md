# lumio_player iOS backend

This backend uses AVQueuePlayer directly, with no `video_player` dependency. Minimum
iOS version: 13. Both CocoaPods and the existing Swift Package source layout use
`lumio_player/Sources/lumio_player`.

## Channels

- Method channel: `lumio_player/methods`
- Shared event channel: `lumio_player/events`

All methods other than `create` require an integer `id`:

| Method | Additional arguments | Result |
| --- | --- | --- |
| `create` | None | `{id, textureId}` |
| `open` | `source`, optional `config` | null; readiness/failure is asynchronous |
| `openPlaylist` | nonempty `sources: [sourceMap, ...]`, required zero-based integer `index`, optional `config` | null; readiness/failure is asynchronous |
| `selectPlaylistItem` | required zero-based integer `index` | null; selects from the opened playlist and pauses |
| `play`, `pause` | None | null |
| `seek` | `positionMs` >= 0 | null when seek completes, or a method error |
| `seekToLive` | None | null when live-edge seek completes, or a method error |
| `volume` | `volume` in 0...1 | null |
| `speed` | `speed` in 0.01...4 | null |
| `looping` | Boolean `looping` | null |
| `diagnostics` | None | Diagnostic map |
| `dispose` | None | null |

`source` has `type: network | file | asset`, a nonempty `uri`, optional string map
`headers`, and optional `format: auto | hls | progressive | dash | rtsp`.
Network URLs must be HTTP(S); files must be absolute paths or file URLs. Asset
URIs are Flutter asset keys, including `packages/<package>/...` when applicable,
resolved through the Flutter registrar and main application bundle.

DASH and RTSP are explicitly rejected, including `.mpd` URL paths and RTSP URL
schemes. `auto`, `hls`, and `progressive` use AVFoundation's format detection;
a format hint cannot make an otherwise unsupported codec/container playable.
An unrecognizable unsupported stream fails asynchronously through AVPlayer.

**Nonempty HTTP headers are rejected with `unsupported_headers`.** This backend
does not use the nonpublic `AVURLAssetHTTPHeaderFieldsKey`. Use signed URLs or
server-side authentication. This applies to **both progressive MP4/audio and HLS**,
including every source in a playlist. Omitted, null, or empty `headers` are accepted;
non-string maps return `invalid_argument`. No custom-scheme resource loader or
URLSession header transport is implemented. A safe progressive implementation would
need verified byte-range/content-information behavior, MIME handling, cancellation,
redirect credential isolation, and real-device playback tests. HLS headers remain
explicitly unsupported until a suitable secure transport is built. App Transport Security, file access, codecs, DRM,
and server support remain subject to normal iOS/AVFoundation restrictions.

`config` defaults to `live: false`, `autoPlay: false`, `looping: false`,
`volume: 1`, `speed: 1`, `loopPlaylist: false`. It accepts `bufferMinMs`, `bufferMaxMs`,
`bufferPlaybackMs`, and `bufferRebufferMs` (nonnegative milliseconds, up to one
day). If both min and max are supplied, min must not exceed max.
Optional `liveTargetOffsetMs` accepts 0...60000 milliseconds; optional
`enableDecoderFallback` must be a boolean. Both are retained in diagnostics but
are **not applied** on iOS. AVPlayer has no equivalent stable live-offset control;
`liveTargetOffsetMs` is not a forward-buffer preference and is never mapped to
`preferredForwardBufferDuration`. `enableDecoderFallback` is an Android-only
setting. Diagnostics list these keys under `unsupportedSettings`.

### Native playlist contract

```text
openPlaylist({id, sources: [sourceMap, ...], index: 0,
              config: {autoPlay: true, looping: false, loopPlaylist: true}})
selectPlaylistItem({id, index: 1})
play({id}) // Only if the parent intends to play after next/previous.
```

Every source and the complete configuration are validated before replacing the
current queue. Invalid/empty lists and missing, boolean, fractional, or out-of-range
indices return `invalid_argument`; a bad source leaves the old playlist installed.
`open` is a one-item playlist and replaces any previous playlist.

The same native `AVQueuePlayer` and Flutter texture are retained across all items.
AVPlayerItems from the selected index through the end are actually queued;
`.actionAtItemEnd = .advance` handles ordinary transitions without Flutter commands.
Earlier items are not played unless selected or reached by a wrap. `config.looping`
repeats the current item and **takes priority** over `loopPlaylist`. Otherwise
`loopPlaylist` wraps the last item to index zero. Repeating/wrapping rebuilds fresh
native items, preserving volume, speed and play intent; wrapping is not promised
to be gapless. The last nonlooping item remains installed at its final position,
with `completed: true`; `play` replays that item, not the whole playlist.

Selection rebuilds the queue at the requested index (even for the same index),
resets position/completion/metadata and **pauses**. Parent next/previous controls
must call `selectPlaylistItem` then `play` only when playback is intended. Playback
failures stop the current item; they do not silently skip it. Per-item KVO,
notifications, output, seeks, frame buffers and diagnostics are reset on every
native transition. Generation and current-item identity guard stale callbacks.

### Buffering limitations

AVPlayer owns startup and rebuffering policy; `automaticallyWaitsToMinimizeStalling`
is enabled. `bufferMaxMs`, or `bufferMinMs` if max is absent, maps to
`AVPlayerItem.preferredForwardBufferDuration`. This is a **preference**, not a
hard maximum or minimum. Zero delegates the preference to AVPlayer.
`bufferPlaybackMs` and `bufferRebufferMs` are retained for diagnostics but cannot
be enforced through AVPlayer's public API. Diagnostics explicitly expose this
policy and the unsupported thresholds. `live` is a state hint, not a transport
mode or a low-latency guarantee.

### Live-edge seeking

`seekToLive({id})` uses the **last** `AVPlayerItem.seekableTimeRanges` range and
seeks to its end minus 0.5 seconds, clamped to that range's start. This fixed
safety margin is independent of the unsupported `liveTargetOffsetMs` setting.
The item must be ready and expose a valid, nonempty, finite seekable range.

Live detection is conservative: indefinite item duration is accepted directly.
For a finite positive duration, `config.live` must be true and the seekable
window must start after zero. A regular full-timeline VOD range starting at zero
is rejected even with a live hint. AVPlayer has no universal live flag: this
finite-window heuristic may reject a live stream before its window advances or
accept a specially constrained finite VOD with an explicit live hint.

Unavailable ranges, unready items, and sources not qualifying as live return
`unsupported_live_seek` and emit a recoverable error event. The selected live
range is authoritative; its target is not clamped to a possibly relative finite
item duration, and indefinite duration is never treated as zero. Live and
ordinary seeks share completion, supersession/cancellation, source-generation,
and disposal handling and preserve the current play/pause intent.

## Events and rendering

Every event includes `id` and `type`. A `state` includes `initialized`, `playing`,
`buffering`, `completed`, `positionMs`, `durationMs`, `width`, `height`,
`bufferedPositionMs`, `live`, `volume`, `speed`, `playlistIndex`, and
`playlistLength`. Index is zero-based; a newly created empty player reports index
zero and length zero. Metadata and duration describe only the current item. `speed` is the configured
playback speed even when paused; `playing` reflects AVPlayer's actual playback
state. An unknown/indefinite duration is reported as zero. `live` is true when
requested or when a ready item's duration is indefinite. Buffered position is
the end of the loaded range containing the current position, rather than the
furthest disconnected loaded range. Seek waits for readiness, clamps to a
known finite duration, and uses milliseconds in the item's timeline.

States are emitted on relevant native changes and every 500 ms on the main
run loop, including while paused. Listening replays each existing player's
current state; cancelling the event subscription does not dispose players.
Errors are not queued when no subscriber is listening, but the latest error
remains available in diagnostics. Validation errors return a Flutter method
error and emit an `error` with `code`, `message`, `details`, and `recoverable`.
Native item/playback failures are marked nonrecoverable for the current item;
a new `open` can still replace it. Interrupted/cancelled seeks return method
errors. Commands on a created player without an item (`play`/`pause`) are no-ops.

Video uses `AVPlayerItemVideoOutput` BGRA CVPixelBuffers and a CADisplayLink.
Flutter's raster-thread `copyPixelBuffer` receives a retained buffer protected
by a lock. Notifications and player/registry operations run on the main thread.
Audio-only sources initialize and play normally with zero video dimensions,
without allocating a display link. Backgrounding pauses frame polling, not
playback; actual background audio requires the host app's audio background
capability. Foregrounding resumes frame polling.

## Audio session and cleanup

When the session still has iOS's default `soloAmbient` category, the plugin
selects `playback` with `mixWithOthers`. An already configured host session is
preserved. AVPlayer manages activation; the plugin does not deactivate the
shared session or restore a potentially stale category on disposal. Session
configuration failures are logged through NSLog without native error text. Interruptions pause playback;
it resumes only if iOS requests resume and the user has not subsequently paused.
Disconnecting an audio output pauses playback.

Opening a new item invalidates its KVO and notification observers, cancels
pending seeks, removes the video output, invalidates the display link, and
releases the previous frame. Dispose additionally invalidates the periodic
timer and lifecycle observers and unregisters the texture. Engine detach
disposes all players and removes the event handler. Queued callbacks are guarded
by source generation and disposal state.

## Diagnostics and validation

`diagnostics` reports item/time-control status, waiting reason, requested and
applied buffer preferences, supported formats/header policy, audio session
category/mixing, requested `liveTargetOffsetMs`/`enableDecoderFallback` (null when
omitted), `unsupportedSettings`, the latest error, and the last 30 AVPlayer access/error log
entries, plus `playlistIndex`, `playlistLength`, and `loopPlaylist`. Access logs
include transfer/bitrate/stall statistics. Source URLs, server addresses, native
error descriptions/userInfo, failure reasons, error domains and error-log comments
are omitted because they may contain credentials or signed URLs. Native failures
use a fixed safe message and numerical `nativeCode`; error logs retain only date
and numerical status. Diagnostics should still be reviewed before upload.

The host-runnable argument/configuration tests use the production parser:

```sh
mkdir -p ios/.native-validation
xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors \
  ios/lumio_player/Sources/lumio_player/LumioConfiguration.swift \
  ios/lumio_player/Sources/lumio_player/LumioLiveSeek.swift \
  ios/Tests/ConfigurationTests.swift -o ios/.native-validation/configuration-tests
ios/.native-validation/configuration-tests
```

The native sources can be compiled against a cached Flutter.framework with
`xcrun swiftc`, targeting an iOS device or simulator SDK in Swift 5 mode (matching
the podspec). Set `SDKROOT` to the same SDK passed to `swiftc -sdk` when linking.
Runtime integration reported by the project maintainer passed on the iOS 26.5
simulator for network video, Flutter assets, local video, audio-only playback,
and native → web → native backend transitions. These results were reported,
not rerun as part of this change. The Dart integration is no longer the generated
old-channel scaffold.

`Tests/NativePlaylistTests.swift` provides iOS XCTest coverage with generated local
audio for native advance/final completion, wrapping, current-item repeat priority,
selection/pause intent, single texture ownership, failure-message sanitization,
replacement, and stale-callback suppression on disposal. Include it with the production sources in an iOS XCTest
host linked to Flutter (not the host-runnable parser executable). These tests were
typechecked against the simulator SDK but **not executed**: there is no configured
iOS XCTest host or booted simulator in this validation session. The production
sources also compiled in Swift 5 mode with warnings treated as errors against
the iOS simulator SDK and cached Flutter.framework. Parser tests executed and passed.
The Flutter integration suite subsequently passed on the iPhone 17 Pro / iOS 26.5 simulator: native playlist auto-advance, previous/next with pause intent, stable texture ownership, and WebView playlist advance with index retained on native reopening. The standalone XCTest suite remains typechecked only; physical-device, queue wrapping and all failure scenarios are not certified by that integration.

Additional runtime coverage should include live HLS `seekToLive`, seek
supersession/disposal, VOD rejection, loop/end events, buffering/failures, audio
interruptions, background/foreground, source replacement, and engine detach.
No Dart or other platform files are changed by this iOS implementation.
