'use strict';
(() => {
  let video = document.getElementById('media');
  let hls = null;
  let disposed = false;
  let initialized = false;
  let buffering = false;
  let requestedLive = false;
  let detectedLive = false;
  let opening = null;
  let generation = 0;
  let autoplay = false;
  let requestedFit = 'contain';
  const applyFit = () => {
    video.style.width = '100%';
    video.style.height = '100%';
    video.style.objectFit = requestedFit === 'scaleDown' ? 'scale-down' : requestedFit;
    if (requestedFit === 'fitWidth' || requestedFit === 'fitHeight') {
      const ratio = video.videoWidth > 0 && video.videoHeight > 0 ? video.videoWidth / video.videoHeight : null;
      video.style.objectFit = ratio ? 'fill' : 'contain';
      if (ratio && requestedFit === 'fitWidth') video.style.height = `${window.innerWidth / ratio}px`;
      if (ratio && requestedFit === 'fitHeight') video.style.width = `${window.innerHeight * ratio}px`;
    }
  };
  const setFit = fit => {
    if (!['contain', 'cover', 'fill', 'fitWidth', 'fitHeight', 'none', 'scaleDown'].includes(fit)) throw new Error('invalid_fit');
    requestedFit = fit;
    applyFit();
  };
  if (typeof window.addEventListener === 'function') window.addEventListener('resize', () => { if (!disposed) applyFit(); });
  const post = event => {
    if (!disposed) window.LumioBridge.postMessage(JSON.stringify(event));
  };
  const ack = (request, ok, code) => {
    if (request != null) post({type: 'ack', request, ok, code});
  };
  const error = (code, message, recoverable, details = {}) => {
    // Never forward browser/HLS messages, URLs, response bodies or headers.
    post({type: 'error', code, message, details: {engine: 'webview', ...details}, recoverable});
  };
  const milliseconds = value => Number.isFinite(value) ? Math.max(0, Math.round(value * 1000)) : 0;
  const state = () => {
    if (disposed) return;
    let bufferedPositionMs = 0;
    for (let i = 0; i < video.buffered.length; i++) {
      if (video.buffered.start(i) <= video.currentTime && video.buffered.end(i) >= video.currentTime) {
        bufferedPositionMs = milliseconds(video.buffered.end(i));
      }
    }
    const level = hls && hls.levels && hls.currentLevel >= 0 ? hls.levels[hls.currentLevel] : null;
    const quality = typeof video.getVideoPlaybackQuality === 'function' ? video.getVideoPlaybackQuality() : null;
    const media = {
      videoCodec: level ? level.videoCodec || null : null,
      audioCodec: level ? level.audioCodec || null : null,
      declaredVariantBitrate: level ? level.bitrate || null : null,
      totalVideoFrames: quality ? quality.totalVideoFrames : null,
      droppedVideoFrames: quality ? quality.droppedVideoFrames : null,
      codecPolicy: 'Codec declared by the selected HLS.js rendition; native HTML decoder is not exposed.'
    };
    post({type: 'state', fit: requestedFit, media, initialized, playing: initialized && !video.paused && !video.ended && !buffering,
      buffering, completed: video.ended, positionMs: milliseconds(video.currentTime),
      durationMs: milliseconds(video.duration), width: video.videoWidth || 0, height: video.videoHeight || 0,
      bufferedPositionMs, live: requestedLive || detectedLive || video.duration === Infinity,
      volume: video.muted ? 0 : video.volume, speed: video.playbackRate});
  };
  const failOpen = code => {
    const request = opening;
    opening = null;
    buffering = false;
    ack(request, false, code);
    state();
  };
  const reset = () => {
    generation++;
    if (opening != null) ack(opening, false, 'open_cancelled');
    opening = null;
    if (hls) { hls.destroy(); hls = null; }
    // New element isolates queued events from previous media resources.
    const old = video;
    const replacement = old.cloneNode(false);
    replacement.removeAttribute('src');
    old.pause();
    old.removeAttribute('src');
    old.load();
    old.replaceWith(replacement);
    video = replacement;
    initialized = false;
    buffering = false;
    requestedLive = false;
    detectedLive = false;
    bind(video, generation);
  };
  const play = async () => {
    try { await video.play(); }
    catch (_) {
      error('playback_blocked', 'Playback was rejected by the browser; retry after a user gesture.', true);
      throw new Error('playback_blocked');
    }
  };
  function bind(element, epoch) {
    const listen = (name, callback) => element.addEventListener(name, () => {
      if (!disposed && epoch === generation) callback();
    });
    listen('loadedmetadata', () => {
      applyFit();
      initialized = true;
      buffering = video.readyState < 3;
      const request = opening;
      opening = null;
      state();
      ack(request, true);
      if (autoplay) void play().catch(() => {});
    });
    for (const name of ['waiting', 'stalled']) listen(name, () => {
      buffering = !video.ended;
      state();
    });
    for (const name of ['canplay', 'playing', 'ended']) listen(name, () => {
      buffering = false;
      state();
    });
    listen('resize', applyFit);
    for (const name of ['pause', 'seeking', 'seeked', 'durationchange', 'volumechange', 'ratechange', 'progress']) {
      listen(name, state);
    }
    listen('error', () => {
      const mediaCode = video.error ? video.error.code : 0;
      error('media_error', 'The browser could not load or decode the media.', mediaCode === 2, {mediaCode});
      failOpen('media_error');
    });
  }
  bind(video, generation);
  const open = (request, args) => {
    reset();
    opening = request;
    requestedLive = args.live;
    setFit(args.fit || requestedFit);
    autoplay = args.autoPlay;
    buffering = true;
    video.loop = args.looping;
    video.volume = args.volume;
        video.muted = args.volume === 0;
    video.playbackRate = args.speed;
    const uri = new URL(args.uri);
    if (!['http:', 'https:'].includes(uri.protocol) || uri.username || uri.password) {
      error('unsupported_source', 'Only HTTP(S) sources are supported.', false);
      failOpen('unsupported_source');
      return;
    }
    const isHls = args.format === 'hls' || (args.format === 'auto' && /\.m3u8$/i.test(uri.pathname));
    if (isHls && !video.canPlayType('application/vnd.apple.mpegurl') && !video.canPlayType('application/x-mpegURL')) {
      if (!window.Hls || !window.Hls.isSupported()) {
        error('unsupported_hls', 'Neither native HLS nor MediaSource HLS is available.', false);
        failOpen('unsupported_hls');
        return;
      }
      const epoch = generation;
      hls = new window.Hls({debug: false, enableWorker: false});
      hls.on(window.Hls.Events.LEVEL_LOADED, (_, data) => {
        if (epoch === generation) { detectedLive = Boolean(data.details.live); state(); }
      });
      hls.on(window.Hls.Events.ERROR, (_, data) => {
        if (epoch !== generation || !data.fatal) return;
        const network = data.type === window.Hls.ErrorTypes.NETWORK_ERROR;
        error(network ? 'hls_network_error' : 'hls_media_error', 'HLS playback failed.', network);
        failOpen(network ? 'hls_network_error' : 'hls_media_error');
        if (hls) { hls.destroy(); hls = null; }
      });
      hls.loadSource(uri.href);
      hls.attachMedia(video);
    } else {
      video.src = uri.href;
      video.load();
    }
    state();
  };
  const receive = async payload => {
    if (disposed) return;
    const {request, method, arguments: args = {}} = payload;
    try {
      switch (method) {
        case 'open': open(request, args); return;
        case 'play': await play(); break;
        case 'pause': video.pause(); break;
        case 'seek': video.currentTime = args.positionMs / 1000; break;
        case 'seekToLive': {
          if (!(requestedLive || detectedLive || video.duration === Infinity) || !video.seekable.length) throw new Error('unsupported_live_seek');
          const range = video.seekable.length - 1;
          const start = video.seekable.start(range);
          const end = video.seekable.end(range);
          const target = hls && Number.isFinite(hls.liveSyncPosition) ? hls.liveSyncPosition : end - 0.5;
          video.currentTime = Math.max(start, Math.min(end, target));
          break;
        }
        case 'fit': setFit(args.fit); break;
        case 'volume': video.volume = args.value; video.muted = args.value === 0; break;
        case 'speed': video.playbackRate = args.value; break;
        case 'looping': video.loop = args.value; break;
        case 'reset': reset(); break;
        case 'dispose': reset(); clearInterval(timer); disposed = true; return;
        default: throw new Error('unsupported_command');
      }
      state();
      ack(request, true);
    } catch (failure) {
      const code = failure && failure.message === 'unsupported_live_seek' ? 'unsupported_live_seek' : 'command_failed';
      error(code, code === 'unsupported_live_seek' ? 'The current media has no available live window.' : 'The browser could not perform the media operation.', true, {method});
      if (method === 'open') failOpen(code);
      else ack(request, false, code);
    }
  };
  const timer = setInterval(state, 500);
  window.LumioPlayer = Object.freeze({receive});
  post({type: 'ready'});
  state();
})();
