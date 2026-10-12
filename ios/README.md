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
| `create` | Optional `viewType: texture \| platformView` (default `texture`) | `{id, textureId}` for texture; `{id}` for platformView |
| `open` | `source`, optional `config` | null; readiness/failure is asynchronous |
| `openPlaylist` | nonempty `sources: [sourceMap, ...]`, required zero-based integer `index`, optional `config` | null; readiness/failure is asynchronous |
| `selectPlaylistItem` | required zero-based integer `index` | null; selects from the opened playlist and pauses |
| `play`, `pause` | None | null |
| `seek` | `positionMs` >= 0 | null when seek completes, or a method error |
| `seekToLive` | None | null when live-edge seek completes, or a method error |
| `volume` | `volume` in 0...1 | null |
| `speed` | `speed` in 0.01...4 | null |
| `looping` | Boolean `looping` | null |
| `getPosition` | None | Nonnegative Int64 milliseconds from `AVQueuePlayer.currentTime()`; zero before opening |
| `diagnostics` | None | Diagnostic map (includes `viewType`; `textureId` is null in platformView mode) |
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

The same native `AVQueuePlayer` and selected rendering mode are retained across all items.
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

### Live network recovery

Native failures use `ios_live_network_interruption` only for configured live media
that reached readiness and has live evidence (indefinite duration or an observed
sliding window). Recognized transient URL errors or a media-services reset are
eligible; an AVFoundation `-11800` wrapper requires a recognized transient cause.
The Dart controller still requires opt-in recovery, foreground/play intent and
an available retry budget. It reopens and seeks live before resuming playback.

Other failures use `ios_native_terminal_error`; `details.nativeErrorPhase` retains
`open_failed` or `playback_failed`. Authentication, TLS, codecs, unknown causes
and evidenced HTTP 401/403/404 are terminal. There is no generic segment-404
recovery: AVPlayer error logs cannot safely distinguish media, manifest and key
requests. Numeric error history is diagnostic; entries retired during healthy
playback do not veto later transient errors. This watermark is not guaranteed
request-level correlation.

Error details contain only allowlisted domain identifiers, numeric codes and the
original phase, never native descriptions, URLs or raw userInfo. Historical and
current error-log status lists are bounded. Test the actual network behavior on
physical iOS devices; parser tests do not prove recovery against a camera.

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
`bufferedPositionMs`, `bufferedRanges`, `live`, `volume`, `speed`, `playlistIndex`, and
`playlistLength`. Index is zero-based; a newly created empty player reports index
zero and length zero. Metadata and duration describe only the current item. `speed` is the configured
playback speed even when paused; `playing` reflects AVPlayer's actual playback
state. An unknown/indefinite duration is reported as zero. `live` is true when
requested or when a ready item's duration is indefinite. Buffered position is
the end of the loaded range containing the current position, rather than the
furthest disconnected loaded range. `bufferedRanges` projects every valid, nonempty,
finite, nonnegative `loadedTimeRanges` interval as `{startMs: Int64, endMs: Int64}`
in the item's timeline. Disconnected intervals remain separate and starts are not
assumed to be zero (including live windows). Invalid intervals are skipped; with no
current item the field reports `[]`. The legacy `bufferedPositionMs` keeps its current-position fallback
and 100 ms start tolerance. Seek waits for readiness, clamps to a
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

### Opt-in native platform view

The raw channel accepts `create({'viewType': 'platformView'})` and returns only
`{'id': id}`. The default `create()` / `create({'viewType': 'texture'})` still returns
`{'id': id, 'textureId': textureId}`. Unknown/non-string/null `viewType` values
return `invalid_argument` before a player is allocated.

The factory is registered as `lumio_player/native_view`. A consuming Dart integration
can mount it as follows (example only; this change does not modify `lib/`):

```dart
final created = await const MethodChannel('lumio_player/methods')
    .invokeMapMethod<String, dynamic>('create', {'viewType': 'platformView'});
final id = created!['id'] as int;
final surface = UiKitView(
  viewType: 'lumio_player/native_view',
  creationParams: {'id': id},
  creationParamsCodec: const StandardMessageCodec(),
);
final positionMs = await const MethodChannel('lumio_player/methods')
    .invokeMethod<int>('getPosition', {'id': id});
```

Supply bounded layout constraints to `surface`. Its `AVPlayerLayer` uses aspect-fit
and the **same AVQueuePlayer** used by commands, state, playlist, readiness and
recovery. This mode never registers a texture, creates a video output or starts
texture-frame polling; the 500 ms state timer remains active. Rendering mode is
fixed at creation. The unchanged public Dart controller/view still defaults to
texture; it does not expose this opt-in yet.

A new surface takes ownership and disconnects the previous layer. Only the current
layer may detach/resume on window lifecycle changes; stale fullscreen/remount
callbacks and old-view deinit cannot detach or reclaim the new layer. Removing a
view from its window disconnects rendering, not playback. Releasing a view never
disposes the player; explicit `dispose({id})` / engine detach disconnects its layer
and frees the player's observers, timer, items and any texture resources. Invalid,
unknown, disposed or texture-mode ids mount an inert black native view because
the factory cannot return a method-channel error.

### Default texture rendering

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
  ios/lumio_player/Sources/lumio_player/LumioTimeline.swift \
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

### Validation of platformView / position / buffered ranges (2026-10-12)

Executed on macOS with Xcode's iPhoneSimulator 27.0 SDK and cached Flutter.framework:

- Configuration/parser executable above: **passed**, including rendering-mode
  defaults/rejections, nonnegative timeline conversion and separate nonzero-start
  buffer ranges (invalid/empty/indefinite ranges excluded).
- Live-error parser executable: **passed** (existing recovery regression coverage).
- All production Swift sources: **compiled and linked**, Swift 5, iOS 13 simulator
  deployment target, warnings treated as errors.
- `NativePlaylistTests`, `NativePlayerViewTests`, `AudioPolicyTests`: **typechecked**
  only. Added coverage for shared queue/layer ownership, old-view callbacks/deinit,
  window detach/reattach, player disposal, zero texture resources, factory codec,
  inert invalid ids, readiness, seek and position. No XCTest execution is claimed.

Reproducible compilation/typecheck from the package root in this environment
(adjust the SDK/cache paths for another machine):

```sh
SDKROOT=/Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
xcrun swiftc -swift-version 5 -warnings-as-errors \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
  -target arm64-apple-ios13.0-simulator \
  -F /opt/homebrew/share/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator \
  -framework Flutter -emit-library -module-name lumio_player \
  ios/lumio_player/Sources/lumio_player/*.swift \
  -o ios/.native-validation/liblumio_player.dylib

xcrun swiftc -swift-version 5 -warnings-as-errors \
  -sdk /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/SDKs/iPhoneSimulator27.0.sdk \
  -target arm64-apple-ios13.0-simulator \
  -F /opt/homebrew/share/flutter/bin/cache/artifacts/engine/ios/Flutter.xcframework/ios-arm64_x86_64-simulator \
  -F /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/Library/Frameworks \
  -I /Applications/Xcode.app/Contents/Developer/Platforms/iPhoneSimulator.platform/Developer/usr/lib \
  -typecheck ios/lumio_player/Sources/lumio_player/*.swift \
  ios/Tests/NativePlaylistTests.swift ios/Tests/NativePlayerViewTests.swift \
  ios/Tests/AudioPolicyTests.swift

xcrun --sdk macosx swiftc -swift-version 5 -warnings-as-errors \
  ios/lumio_player/Sources/lumio_player/LumioLiveError.swift \
  ios/Tests/LiveErrorTests.swift -o ios/.native-validation/live-error-tests
ios/.native-validation/live-error-tests
```

The first XCTest typecheck attempt lacked the XCTest framework search path and
failed with `no such module 'XCTest'`; the complete command above passed. There
was no booted simulator or configured standalone XCTest host. New platform-view
rendering, fullscreen transitions, HLS loaded ranges, background rendering and
physical-device playback still require runtime validation. The historical
integration results above do **not** certify this opt-in rendering mode.

Additional runtime coverage should include live HLS `seekToLive`, seek
supersession/disposal, VOD rejection, loop/end events, buffering/failures, audio
interruptions, background/foreground, source replacement, and engine detach.
No Dart or other platform files are changed by this iOS implementation.
