const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

test('HTML keeps viewport and centered media CSS inside a valid document structure', () => {
  const html = fs.readFileSync(`${__dirname}/player.html`, 'utf8');
  assert.equal((html.match(/<head>/g) || []).length, 1);
  assert.equal((html.match(/<\/head>/g) || []).length, 1);
  assert.equal((html.match(/<body>/g) || []).length, 1);
  assert.equal((html.match(/<\/body>/g) || []).length, 1);
  assert.match(html, /<head>\s*<meta charset="utf-8">/);
  assert.match(html, /<meta name="viewport" content="width=device-width,initial-scale=1,maximum-scale=1">/);
  const head = html.match(/<head>([\s\S]*?)<\/head>/)[1];
  assert.equal((head.match(/<style>/g) || []).length, 1);
  assert.equal((head.match(/<\/style>/g) || []).length, 1);
  const css = head.match(/<style>([\s\S]*?)<\/style>/)[1];
  assert.match(css, /html,body\{margin:0;width:100%;height:100%;overflow:hidden;background:#000\}/);
  assert.match(css, /video\{position:absolute;left:50%;top:50%;transform:translate\(-50%,-50%\);width:100%;height:100%;object-fit:contain;object-position:center\}/);
  assert.match(html, /<\/head>\s*<body>\s*<video id="media" playsinline webkit-playsinline preload="auto"><\/video>\s*<script src="player.js"><\/script>\s*<\/body>/);
});

function harness({nativeHls = false, hls = false, destroyFails = false, pauseFails = false, frameCallback = false} = {}) {
  const events = [];
  let current;
  let interval;
  class Media {
    constructor() {
      this.style = {};
      this.listeners = {}; this.paused = true; this.ended = false;
      this.currentTime = 0; this.duration = NaN; this.volume = 1;
      this.playbackRate = 1; this.readyState = 0;
      this.buffered = {length: 0};
      if (frameCallback) {
        this.frameCallbacks = [];
        this.cancelledFrames = [];
        this.requestVideoFrameCallback = fn => { this.frameCallbacks.push(fn); return this.frameCallbacks.length; };
        this.cancelVideoFrameCallback = id => this.cancelledFrames.push(id);
      }
    }
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
    emit(name) { for (const fn of this.listeners[name] || []) fn(); }
    cloneNode() { return new Media(); }
    removeEventListener(name, fn) { this.listeners[name] = (this.listeners[name] || []).filter(listener => listener !== fn); }
    removeAttribute(name) { if (name === 'src') { delete this.src; this.sourceRemoved = true; } }
    replaceWith(next) { current = next; }
    load() { this.loads = (this.loads || 0) + 1; }
    pause() { if (pauseFails && this.failPause) throw new Error('pause failed'); this.paused = true; }
    async play() { this.paused = false; }
    canPlayType() { return nativeHls ? 'maybe' : ''; }
  }
  class Hls {
    static Events = {LEVEL_LOADED: 'level', ERROR: 'error'};
    static ErrorTypes = {NETWORK_ERROR: 'network'};
    static isSupported() { return true; }
    constructor() { Hls.instance = this; this.handlers = {}; }
    on(name, fn) { this.handlers[name] = fn; }
    loadSource(uri) { this.uri = uri; }
    attachMedia(media) { this.media = media; }
    destroy() { this.destroyed = true; if (destroyFails) throw new Error('destroy failed'); }
  }
  current = new Media();
  const windowListeners = {};
  const window = {innerWidth: 800, innerHeight: 600,
    addEventListener: (name, fn) => { windowListeners[name] = fn; },
    removeEventListener: (name, fn) => { if (windowListeners[name] === fn) delete windowListeners[name]; },
    LumioBridge: {postMessage: s => events.push(JSON.parse(s))}};
  if (hls) window.Hls = Hls;
  vm.runInNewContext(fs.readFileSync(`${__dirname}/player.js`, 'utf8'), {
    window, document: {getElementById: () => current}, URL,
    setInterval: fn => { interval = fn; return 1; }, clearInterval: () => { interval = null; },
  });
  return {events, window, windowListeners, Hls, media: () => current, interval: () => interval,
    receive: (method, args = {}, request = 1) => window.LumioPlayer.receive({method, arguments: args, request})};
}
const source = {uri: 'https://example.com/private.m3u8?secret=token', format: 'hls',
  live: false, autoPlay: false, looping: false, volume: 0.5, speed: 1.25};

test('advancing video falls back to decoded data when an available frame callback never arrives', async () => {
  const h = harness({nativeHls: true, frameCallback: true});
  await h.receive('open', {...source, live: true});
  const media = h.media();
  media.videoWidth = 1920;
  media.videoHeight = 1080;
  media.readyState = 3;
  media.emit('loadedmetadata');
  await h.receive('play');
  media.emit('playing');
  let state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.hasRenderedFirstFrame, false);
  assert.equal(state.firstFrameSupported, true);
  media.currentTime = 1;
  media.emit('timeupdate');
  state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.buffering, false);
  assert.equal(state.playing, true);
  assert.equal(state.hasRenderedFirstFrame, true);
  assert.equal(state.firstFrameEvidence, 'loadedData');
  assert.deepEqual(media.cancelledFrames, [1]);
  // A late callback must not overwrite the qualified fallback evidence.
  media.frameCallbacks[0]();
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).firstFrameEvidence, 'loadedData');
  await h.receive('open', source, 9);
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).hasRenderedFirstFrame, false);
  media.emit('timeupdate');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).hasRenderedFirstFrame, false);
});

test('frame callback fallback does not claim data for stalled, paused, seeking or audio playback', async () => {
  for (const mode of ['stalled', 'paused', 'seeking', 'audio', 'noVideoSize', 'noProgress']) {
    const h = harness({nativeHls: true, frameCallback: true});
    await h.receive('open', {...source, mode: mode === 'audio' ? 'audio' : 'live'});
    const media = h.media();
    media.videoWidth = mode === 'noVideoSize' ? 0 : 1920;
    media.videoHeight = mode === 'noVideoSize' ? 0 : 1080;
    media.readyState = mode === 'stalled' ? 2 : 3;
    media.emit('loadedmetadata');
    await h.receive('play');
    media.paused = mode === 'paused';
    media.seeking = mode === 'seeking';
    media.currentTime = mode === 'noProgress' ? 0 : 1;
    media.emit('timeupdate');
    const state = h.events.filter(e => e.type === 'state').at(-1);
    assert.equal(state.hasRenderedFirstFrame, false, mode);
  }
});

test('ready handshake, metadata acknowledgment and audio-only state protocol', async () => {
  const h = harness({nativeHls: true});
  assert.equal(h.events[0].type, 'ready');
  await h.receive('open', source);
  assert.equal(h.events.some(e => e.type === 'ack'), false);
  h.media().duration = 60;
  h.media().emit('loadedmetadata');
  assert.equal(h.events.find(e => e.type === 'ack').ok, true);
  const state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.initialized, true);
  assert.equal(state.durationMs, 60000);
  assert.equal(state.width, 0);
  assert.equal(state.height, 0);
  assert.equal('id' in state, false);
  await h.receive('seek', {positionMs: 1500}, 2);
  assert.equal(h.media().currentTime, 1.5);
  await h.receive('volume', {value: 0.2}, 3);
  assert.equal(h.media().volume, 0.2);
  await h.receive('speed', {value: 2}, 4);
  assert.equal(h.media().playbackRate, 2);
  await h.receive('looping', {value: true}, 5);
  assert.equal(h.media().loop, true);
  await h.receive('play', {}, 6);
  assert.equal(h.media().paused, false);
  await h.receive('pause', {}, 7);
  assert.equal(h.media().paused, true);
});

test('video-only playback does not wait for audio and stalled fetching does not imply buffering', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', {...source, live: true, volume: 0});
  const media = h.media();
  // No audio track information is provided by this video-only source.
  media.videoWidth = 1920;
  media.videoHeight = 1080;
  media.readyState = 3;
  media.emit('loadedmetadata');
  assert.equal(h.events.find(e => e.type === 'ack').ok, true);
  await h.receive('play');
  media.emit('playing');
  media.emit('stalled');
  let state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.initialized, true);
  assert.equal(state.buffering, false);
  assert.equal(state.playing, true);

  media.readyState = 2;
  media.emit('waiting');
  state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.buffering, true);
  // Resume without another canplay/playing event: real progress clears the flag.
  media.readyState = 3;
  media.currentTime = 1;
  media.emit('timeupdate');
  state = h.events.filter(e => e.type === 'state').at(-1);
  assert.equal(state.buffering, false);
  assert.equal(state.playing, true);
});

test('first frame callback is one-shot, independent of audio and guarded on reset/dispose', async () => {
  const h = harness({nativeHls: true, frameCallback: true});
  const latest = () => h.events.filter(e => e.type === 'state').at(-1);
  await h.receive('open', source);
  const old = h.media();
  old.videoWidth = 1920; old.videoHeight = 1080; old.readyState = 3;
  old.emit('loadedmetadata');
  assert.equal(latest().initialized, true);
  assert.equal(latest().firstFrameSupported, true);
  assert.equal(latest().hasRenderedFirstFrame, false);
  old.emit('loadeddata');
  assert.equal(old.frameCallbacks.length, 1);
  old.frameCallbacks[0]();
  assert.equal(latest().hasRenderedFirstFrame, true);
  assert.equal(latest().firstFrameEvidence, 'requestVideoFrameCallback');
  const count = h.events.length;
  old.frameCallbacks[0]();
  assert.equal(h.events.length, count);
  await h.receive('open', source, 2);
  assert.equal(latest().hasRenderedFirstFrame, false);
  old.frameCallbacks[0]();
  assert.equal(latest().hasRenderedFirstFrame, false);
  const media = h.media();
  media.videoWidth = 640; media.videoHeight = 360;
  media.emit('loadedmetadata');
  await h.receive('open', source, 3);
  assert.deepEqual(media.cancelledFrames, [1]);
  media.frameCallbacks[0]();
  assert.equal(latest().hasRenderedFirstFrame, false);
  const last = h.media();
  last.videoWidth = 640; last.videoHeight = 360;
  last.emit('loadedmetadata');
  await h.receive('dispose', {}, 4);
  assert.deepEqual(last.cancelledFrames, [1]);
  const disposedCount = h.events.length;
  last.frameCallbacks[0]();
  assert.equal(h.events.length, disposedCount);
});

test('loaded data fallback is explicit; metadata alone and audio mode do not claim frames', async () => {
  const h = harness({nativeHls: true});
  const latest = () => h.events.filter(e => e.type === 'state').at(-1);
  await h.receive('open', source);
  const media = h.media();
  media.videoWidth = 640; media.videoHeight = 360; media.readyState = 1;
  media.emit('loadedmetadata');
  assert.equal(latest().firstFrameSupported, false);
  assert.equal(latest().hasRenderedFirstFrame, false);
  media.readyState = 2;
  media.emit('loadeddata');
  assert.equal(latest().hasRenderedFirstFrame, true);
  assert.equal(latest().firstFrameSupported, true);
  assert.equal(latest().firstFrameEvidence, 'loadedData');
  await h.receive('open', {...source, mode: 'audio'});
  h.media().videoWidth = 640; h.media().videoHeight = 360; h.media().readyState = 3;
  h.media().emit('loadedmetadata'); h.media().emit('loadeddata');
  assert.equal(latest().initialized, true);
  assert.equal(latest().hasRenderedFirstFrame, false);
  assert.equal(latest().firstFrameSupported, false);
});

test('buffering remains visible without sufficient data or actual playback progress', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', source);
  const media = h.media();
  media.emit('loadedmetadata');
  await h.receive('play');
  media.readyState = 2;
  media.emit('stalled');
  media.currentTime = 1;
  media.emit('timeupdate');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).buffering, true);
  media.readyState = 3;
  media.emit('timeupdate'); // Clock still stopped.
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).buffering, true);
  media.paused = true;
  media.currentTime = 2;
  media.emit('timeupdate');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).buffering, true);
  media.paused = false;
  media.seeking = true;
  media.currentTime = 3;
  media.emit('timeupdate');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).buffering, true);
  media.seeking = false;
  media.currentTime = 4;
  media.emit('timeupdate');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).buffering, false);
});

test('buffer state preserves real gaps and position query acknowledges actual paused media time', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', source);
  h.media().emit('loadedmetadata');
  h.media().currentTime = 2;
  h.media().buffered = {length: 2, start: i => [1, 7][i], end: i => [4, 10][i]};
  h.media().emit('progress');
  const state = h.events.filter(e => e.type === 'state').at(-1);
  assert.deepEqual(state.bufferedRanges, [{startMs: 1000, endMs: 4000}, {startMs: 7000, endMs: 10000}]);
  assert.equal(state.bufferedPositionMs, 4000);
  h.media().currentTime = 3.456;
  await h.receive('getPosition', {}, 31);
  assert.equal(h.events.find(e => e.type === 'ack' && e.request === 31).data, 3456);
  assert.equal(h.media().paused, true);
  // The query doesn't need or fabricate a periodic state update.
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).positionMs, 2000);
  await h.receive('open', source, 32);
  assert.deepEqual(h.events.filter(e => e.type === 'state').at(-1).bufferedRanges, []);
  await h.receive('getPosition', {}, 33);
  assert.equal(h.events.find(e => e.type === 'ack' && e.request === 33).ok, false);
});

test('native HLS preferred; fallback uses bundled HLS with sanitized fatal errors', async () => {
  const native = harness({nativeHls: true, hls: true});
  await native.receive('open', source);
  assert.equal(native.Hls.instance, undefined);
  const h = harness({hls: true});
  await h.receive('open', source);
  const instance = h.Hls.instance;
  instance.handlers.level(null, {details: {live: true}});
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).live, true);
  instance.handlers.error(null, {fatal: true, type: 'network', url: source.uri, details: source.uri});
  const error = h.events.find(e => e.type === 'error');
  assert.equal(error.code, 'hls_network_error');
  assert.equal(error.recoverable, true);
  assert.equal(JSON.stringify(h.events).includes('secret'), false);
  assert.equal(instance.destroyed, true);
});

test('replacement cancels pending open and suppresses stale metadata', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', source, 1);
  const old = h.media();
  await h.receive('open', source, 2);
  old.emit('loadedmetadata');
  assert.equal(h.events.some(e => e.request === 1 && e.ok === false), true);
  assert.equal(h.events.some(e => e.request === 2 && e.ok === true), false);
  h.media().emit('loadedmetadata');
  assert.equal(h.events.some(e => e.request === 2 && e.ok === true), true);
});

test('fit modes update CSS and survive source changes and metadata loading', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', {...source, fit: 'cover'});
  assert.equal(h.media().style.objectFit, 'cover');
  h.media().videoWidth = 1920;
  h.media().videoHeight = 1080;
  h.media().emit('loadedmetadata');
  await h.receive('fit', {fit: 'contain'});
  assert.equal(h.media().style.objectFit, 'contain');
  await h.receive('fit', {fit: 'fill'});
  assert.equal(h.media().style.objectFit, 'fill');
  await h.receive('fit', {fit: 'fitWidth'});
  assert.equal(h.media().style.height, '450px');
  await h.receive('fit', {fit: 'fitHeight'});
  assert.ok(Math.abs(parseFloat(h.media().style.width) - 600 * 1920 / 1080) < 0.001);
  await h.receive('fit', {fit: 'scaleDown'});
  assert.equal(h.media().style.objectFit, 'scale-down');
  await h.receive('open', source);
  assert.equal(h.media().style.objectFit, 'scale-down');
  assert.equal(h.events.filter(e => e.type === 'state').at(-1).fit, 'scaleDown');
});

test('dispose acknowledges only after teardown and cancels pending open', async () => {
  const h = harness({hls: true});
  await h.receive('open', source, 10);
  const media = h.media();
  const engine = h.Hls.instance;
  const post = h.window.LumioBridge.postMessage;
  h.window.LumioBridge.postMessage = message => {
    const event = JSON.parse(message);
    if (event.type === 'ack' && event.request === 11) {
      assert.equal(engine.destroyed, true);
      assert.equal(media.paused, true);
      assert.equal(media.sourceRemoved, true);
      assert.equal(media.loads, 1);
      assert.equal(Object.values(media.listeners).flat().length, 0);
      assert.equal(h.windowListeners.resize, undefined);
      assert.equal(h.interval(), null);
    }
    post(message);
  };
  await h.receive('dispose', {}, 11);
  assert.deepEqual(h.events.filter(e => e.type === 'ack').map(e => [e.request, e.ok]), [[10, false], [11, true]]);
  const count = h.events.length;
  engine.handlers.level(null, {details: {live: true}});
  media.emit('loadedmetadata');
  await h.receive('dispose', {}, 12);
  assert.equal(h.events.length, count);
});

test('dispose without request remains silent after metadata acknowledgment', async () => {
  const h = harness({nativeHls: true});
  await h.receive('open', source);
  h.media().emit('loadedmetadata');
  const count = h.events.length;
  await h.window.LumioPlayer.receive({method: 'dispose'});
  assert.equal(h.events.length, count);
  assert.equal(h.interval(), null);
});

test('dispose attempts remaining resources after HLS destroy or media pause failure', async () => {
  const h = harness({hls: true, destroyFails: true, pauseFails: true});
  await h.receive('open', source);
  const media = h.media();
  media.failPause = true;
  await h.receive('dispose', {}, 20);
  assert.equal(h.Hls.instance.destroyed, true);
  assert.equal(media.sourceRemoved, true);
  assert.equal(media.loads, 1);
  assert.equal(Object.values(media.listeners).flat().length, 0);
  assert.equal(h.windowListeners.resize, undefined);
  assert.equal(h.interval(), null);
  assert.deepEqual(h.events.at(-1), {type: 'ack', request: 20, ok: false, code: 'command_failed'});
  const count = h.events.length;
  await h.receive('play');
  assert.equal(h.events.length, count);
});

test('unsupported HLS and local sources fail explicitly; disposal stops events', async () => {
  const h = harness();
  await h.receive('open', source);
  assert.equal(h.events.find(e => e.type === 'error').code, 'unsupported_hls');
  await h.receive('open', {...source, uri: 'file:///secret.mp4'}, 2);
  assert.equal(h.events.some(e => e.code === 'unsupported_source'), true);
  await h.receive('dispose');
  const count = h.events.length;
  await h.receive('play');
  h.media().emit('loadedmetadata');
  assert.equal(h.events.length, count);
  assert.equal(h.interval(), null);
});
