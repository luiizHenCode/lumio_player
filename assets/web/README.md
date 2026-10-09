# Bundled WebView media engine

Register `assets/web/` as a Flutter package asset directory in `lumio_player/pubspec.yaml`. The engine loads `packages/lumio_player/assets/web/player.html`; its JS dependencies are relative bundled assets. No runtime CDN is used.

## Integration

Create `LumioWebEngine(onEvent: callback)`, mount a `WebViewWidget(controller: engine.controller)` **while** `open()` is pending, and optionally call `acknowledgeMounted()` (diagnostic only). Do not gate widget creation on successful initialization. `open` includes bridge readiness and metadata loading in a single timeout: `config.initializationTimeoutMs`, default 25000, accepted range 1–120000. Dispose the engine and remove the widget to release the platform view.

The API accepts plain maps with no model/controller dependencies. `open(source, config)` accepts network HTTP(S) URI, empty/absent headers, and format `auto`, `hls` or `progressive`. `auto` recognizes HLS by the URL pathname's `.m3u8` extension; use explicit `hls` for extensionless manifests. Config keys: `live`, `autoPlay` (default true), `looping`, `volume` (0–1), `speed` (0.25–4), `initializationTimeoutMs`. Commands: `play`, `pause`, `seek` with `positionMs`, `volume`/`speed`/`looping` with the matching named key or `value`.

State/error events use the Android protocol without `id`; private readiness/acknowledgment messages are not forwarded. `open` succeeds on metadata, not autoplay success. Autoplay rejection emits a recoverable error. Validation, initialization and operation failures complete futures with errors; cancellation/disposal fail pending opens. An outer Dart timeout does not cancel its underlying Future; call `dispose()` if the caller abandons initialization.

## Limitations and security

- No local file or Flutter asset playback, arbitrary file access, custom headers, DASH, RTSP, DRM or background playback.
- Uses a video element for both video and audio-only sources. Rendering audio-only media is black; dimensions remain zero.
- Native HLS is preferred. HLS.js fallback requires MediaSource/codecs and CORS permission on **all** manifests, segments and keys. Progressive/native media support depends on the OS browser. Transport security/cleartext policy must be configured by the app when needed.
- JavaScript payloads are encoded as JSON string literals. Diagnostics and emitted errors exclude URLs, headers, raw browser errors and HLS response content. HLS debug logging is disabled. Browser/network developer tools can still expose media requests; this is not a network anonymization layer.
- Browser autoplay rules, live seeking, codec support, and iOS volume control restrictions still apply. State reflects actual browser values, not assumed requested settings.
- Navigation is restricted to bootstrap of the bundled HTML. There are no runtime external scripts. Media requests still go to the supplied server and its referenced resources.
- Removing the widget remains necessary: WebViewController does not offer a cross-platform dispose method.

## Third-party licensing

`hls-1.6.13.min.js` is pinned HLS.js **1.6.13**, downloaded from `https://cdn.jsdelivr.net/npm/hls.js@1.6.13/dist/hls.min.js`. Copyright notices and upstream licensing are in `HLS-LICENSE.txt`; the full Apache License 2.0 is in `APACHE-2.0.txt`. Preserve these when redistributing. No changes were made to the upstream minified build.

## Isolated validation

`node --check assets/web/player.js`

`node --test assets/web/player.test.cjs`

The tests use an isolated DOM/media/bridge fake for protocol and lifecycle checks, not real decoder or device playback. Device tests are required for WKWebView, Android WebView, CORS and autoplay behavior.
