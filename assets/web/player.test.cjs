const {test} = require('node:test');
const assert = require('node:assert/strict');
const vm = require('node:vm');
const fs = require('node:fs');

function harness({nativeHls = false, hls = false} = {}) {
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
    }
    addEventListener(name, fn) { (this.listeners[name] ||= []).push(fn); }
    emit(name) { for (const fn of this.listeners[name] || []) fn(); }
    cloneNode() { return new Media(); }
    removeAttribute() {}
    replaceWith(next) { current = next; }
    load() {}
    pause() { this.paused = true; }
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
    destroy() { this.destroyed = true; }
  }
  current = new Media();
  const window = {innerWidth: 800, innerHeight: 600, LumioBridge: {postMessage: s => events.push(JSON.parse(s))}};
  if (hls) window.Hls = Hls;
  vm.runInNewContext(fs.readFileSync(`${__dirname}/player.js`, 'utf8'), {
    window, document: {getElementById: () => current}, URL,
    setInterval: fn => { interval = fn; return 1; }, clearInterval: () => { interval = null; },
  });
  return {events, window, Hls, media: () => current, interval: () => interval,
    receive: (method, args = {}, request = 1) => window.LumioPlayer.receive({method, arguments: args, request})};
}
const source = {uri: 'https://example.com/private.m3u8?secret=token', format: 'hls',
  live: false, autoPlay: false, looping: false, volume: 0.5, speed: 1.25};

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
