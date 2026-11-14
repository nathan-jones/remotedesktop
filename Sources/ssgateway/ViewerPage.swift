/// The page the gateway serves: decodes the video with WebCodecs and turns
/// touches, the mouse and the keyboard into messages for the gateway.
enum ViewerPage {
    static let html = #"""
<!doctype html>
<html lang="en">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1, maximum-scale=1, user-scalable=no, viewport-fit=cover">
<meta name="apple-mobile-web-app-capable" content="yes">
<meta name="mobile-web-app-capable" content="yes">
<title>Remote Desktop</title>
<style>
  * { box-sizing: border-box; -webkit-tap-highlight-color: transparent; }
  html, body {
    margin: 0; height: 100%; background: #000; color: #f5f5f7; overflow: hidden;
    font: 17px/1.4 -apple-system, system-ui, sans-serif;
    touch-action: none; overscroll-behavior: none; -webkit-user-select: none; user-select: none;
    -webkit-touch-callout: none;
  }
  #stage { position: fixed; left: 0; top: 0; width: 100%; height: 100%; overflow: hidden; touch-action: none; }
  #screen { position: absolute; display: none; }
  #screen.mouse { cursor: none; }
  #cursor { position: absolute; left: 0; top: 0; display: none; pointer-events: none; transform-origin: 0 0; }
  #typing {
    position: fixed; left: 0; bottom: 0; width: 1px; height: 1px; opacity: 0; border: 0; padding: 0;
    font-size: 16px; background: transparent; color: transparent; caret-color: transparent;
  }
  #keyboard {
    position: fixed; right: 10px; width: 46px; height: 46px; border-radius: 23px; border: 0; padding: 0;
    background: rgba(60, 60, 67, 0.72); color: #fff; font-size: 22px; display: none;
    -webkit-backdrop-filter: blur(12px); backdrop-filter: blur(12px);
  }
  #keys {
    position: fixed; left: 0; width: 100%; height: 48px; display: none; gap: 6px; padding: 5px 6px;
    background: rgba(28, 28, 30, 0.92); overflow-x: auto;
  }
  #keys button {
    flex: 1 0 auto; min-width: 42px; border: 0; border-radius: 8px; padding: 0 10px;
    background: #48484a; color: #fff; font: inherit; font-size: 16px;
  }
  #keys button.held { background: #0a84ff; }
  #status {
    position: fixed; left: 0; top: 0; width: 100%; height: 100%; display: flex; align-items: center;
    justify-content: center; padding: 24px; text-align: center; pointer-events: none;
  }
  #card {
    max-width: 420px; padding: 22px 24px; border-radius: 18px; background: rgba(28, 28, 30, 0.94);
    pointer-events: auto; -webkit-user-select: text; user-select: text;
  }
  #message { font-size: 19px; font-weight: 600; }
  #detail { margin-top: 6px; color: #a1a1a6; overflow-wrap: anywhere; }
  #card input {
    display: none; width: 100%; margin-top: 14px; padding: 11px 12px; border-radius: 10px; border: 1px solid #48484a;
    background: #000; color: #fff; font: inherit; font-size: 20px; text-align: center; letter-spacing: 0.08em;
  }
  #card button {
    display: none; margin-top: 14px; padding: 11px 22px; border: 0; border-radius: 10px;
    background: #0a84ff; color: #fff; font: inherit; font-weight: 600;
  }
</style>
</head>
<body>
<div id="stage">
  <canvas id="screen"></canvas>
  <canvas id="cursor"></canvas>
</div>
<input id="typing" type="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" aria-label="Type on the Mac">
<button id="keyboard" aria-label="Keyboard">⌨</button>
<div id="keys">
  <button data-key="0xFF1B">esc</button>
  <button data-key="0xFF09">tab</button>
  <button data-modifier="0xFFE3">⌃</button>
  <button data-modifier="0xFFE9">⌥</button>
  <button data-modifier="0xFFEB">⌘</button>
  <button data-key="0xFF51">←</button>
  <button data-key="0xFF54">↓</button>
  <button data-key="0xFF52">↑</button>
  <button data-key="0xFF53">→</button>
</div>
<div id="status">
  <div id="card">
    <div id="message">Connecting…</div>
    <div id="detail"></div>
    <input id="code" type="text" autocomplete="off" autocorrect="off" autocapitalize="off" spellcheck="false" placeholder="Access code">
    <button id="action">Connect</button>
  </div>
</div>

<script>
'use strict';

const $ = id => document.getElementById(id);
const stage = $('stage'), screenCanvas = $('screen'), cursorCanvas = $('cursor'), typing = $('typing');
const picture = screenCanvas.getContext('2d', { alpha: false });
const clamp = (value, low, high) => Math.min(Math.max(value, low), high);

const Key = {
  backspace: 0xFF08, tab: 0xFF09, enter: 0xFF0D, escape: 0xFF1B, delete: 0xFFFF,
  left: 0xFF51, up: 0xFF52, right: 0xFF53, down: 0xFF54,
  shift: 0xFFE1, control: 0xFFE3, option: 0xFFE9, command: 0xFFEB,
};
const Button = { left: 1, right: 2, scrollUp: 8, scrollDown: 16 };

let socket = null;
let accessCode = '';
try { accessCode = decodeURIComponent(location.hash.slice(1)); } catch (e) {}

// ------------------------------------------------------------------- Status

function showStatus(message, detail, mode) {
  $('status').style.display = 'flex';
  $('message').textContent = message;
  $('detail').textContent = detail || '';
  $('code').style.display = mode === 'code' ? 'block' : 'none';
  $('action').style.display = mode ? 'inline-block' : 'none';
  $('action').textContent = mode === 'code' ? 'Connect' : 'Reconnect';
}
function hideStatus() { $('status').style.display = 'none'; }

$('action').onclick = () => {
  if ($('code').style.display !== 'none') accessCode = $('code').value.trim().toLowerCase();
  if (!accessCode) return;
  $('code').blur();
  connect();
};
$('code').addEventListener('keydown', e => { e.stopPropagation(); if (e.key === 'Enter') $('action').click(); });

// --------------------------------------------------------------- Connection

let ended = false;

function connect() {
  if (!('VideoDecoder' in window)) {
    showStatus('This browser cannot show the Mac’s screen.', 'It has no WebCodecs video decoder.');
    return;
  }
  if (!accessCode) {
    showStatus('Enter the access code', 'The gateway prints it when it starts.', 'code');
    return;
  }
  ended = false;
  hasVideo = false;
  decoderErrors = 0;
  showStatus('Connecting…');
  const ws = new WebSocket('ws://' + location.hostname + ':' + (Number(location.port || 80) + 1) + '/');
  ws.binaryType = 'arraybuffer';
  socket = ws;
  ws.onopen = () => {
    sentSize = viewportSize();
    ws.send(JSON.stringify({ t: 'hello', code: accessCode, ...sentSize }));
  };
  ws.onmessage = event => {
    if (ws !== socket) return;
    if (typeof event.data === 'string') onText(JSON.parse(event.data)); else onBinary(event.data);
  };
  ws.onclose = () => {
    if (ws !== socket) return;
    socket = null;
    closeDecoder();
    releaseEverything();
    if (!ended) showStatus('Disconnected', 'The connection to the gateway was lost.', 'retry');
  };
}

function send(message) {
  if (socket && socket.readyState === WebSocket.OPEN) socket.send(JSON.stringify(message));
}

function onText(message) {
  switch (message.t) {
    case 'state':
      if (!hasVideo) showStatus({ connecting: 'Connecting to the Mac…', authenticating: 'Signing in…',
        negotiating: 'Starting video…', streaming: 'Waiting for video…' }[message.state] || 'Connecting…');
      break;
    case 'space':
      setSpace(message.w, message.h);
      break;
    case 'note':
      if (!hasVideo && !ended) $('detail').textContent = message.text;
      break;
    case 'denied':
      ended = true;
      accessCode = '';
      showStatus('That access code was not accepted', 'The gateway prints the code when it starts.', 'code');
      break;
    case 'closed':
      ended = true;
      showStatus('Disconnected', message.reason, 'retry');
      break;
  }
}

function onBinary(buffer) {
  const view = new DataView(buffer);
  switch (view.getUint8(0)) {
    case 1: configure(new Uint8Array(buffer, 5), view.getUint16(1), view.getUint16(3)); break;
    case 2: decode(view.getUint8(1) === 1, new Uint8Array(buffer, 6)); break;
    case 3: setCursor(view.getUint16(1), view.getUint16(3), view.getUint16(5), view.getUint16(7), new Uint8Array(buffer, 9)); break;
  }
}

// -------------------------------------------------------------------- Video

let decoder = null, configuration = null, waitingForKeyframe = true, hasVideo = false;
let chunkNumber = 0, decoderErrors = 0;
const submitted = new Map();
const stats = { frames: 0, delays: [] };

// RFC 6381 codec string from an hvcC record.
function codecString(d) {
  const space = ['', 'A', 'B', 'C'][d[1] >> 6];
  const compat = ((d[2] << 24) | (d[3] << 16) | (d[4] << 8) | d[5]) >>> 0;
  let reversed = 0;
  for (let i = 0; i < 32; i++) reversed = ((reversed << 1) | ((compat >>> i) & 1)) >>> 0;
  const constraints = Array.from(d.slice(6, 12));
  while (constraints.length && constraints[constraints.length - 1] === 0) constraints.pop();
  return 'hvc1.' + space + (d[1] & 0x1f) + '.' + reversed.toString(16).toUpperCase() + '.' +
    ((d[1] >> 5) & 1 ? 'H' : 'L') + d[12] + constraints.map(b => '.' + b.toString(16).toUpperCase()).join('');
}

function closeDecoder() {
  if (decoder && decoder.state !== 'closed') { try { decoder.close(); } catch (e) {} }
  decoder = null;
  submitted.clear();
}

function configure(record, width, height) {
  configuration = {
    codec: codecString(record), codedWidth: width, codedHeight: height,
    description: record.slice(), optimizeForLatency: true, hardwareAcceleration: 'prefer-hardware',
  };
  openDecoder();
}

function openDecoder() {
  closeDecoder();
  waitingForKeyframe = true;
  const mine = new VideoDecoder({
    output(frame) {
      if (mine !== decoder) { frame.close(); return; }
      show(frame);
    },
    error(error) {
      if (mine !== decoder) return;
      const text = configuration.codec + ' ' + configuration.codedWidth + 'x' + configuration.codedHeight + ': ' +
        (error.name || 'error') + ' ' + (error.message || error);
      send({ t: 'log', m: 'decoder error, ' + text });
      decoder = null;
      // Start again from a fresh keyframe, unless it never works.
      if (++decoderErrors >= 5) {
        ended = true;
        showStatus('This browser cannot decode the Mac’s video', text);
        if (socket) socket.close();
      } else if (configuration && socket) { openDecoder(); send({ t: 'kf' }); }
    },
  });
  decoder = mine;
  try {
    mine.configure(configuration);
  } catch (error) {
    decoder = null;
    ended = true;
    send({ t: 'log', m: 'configure failed, ' + configuration.codec + ': ' + (error.message || error) });
    showStatus('This browser cannot decode the Mac’s video', configuration.codec + ': ' + (error.message || error));
    if (socket) socket.close();
  }
}

function decode(isKeyframe, data) {
  if (!decoder) return;
  if (isKeyframe) waitingForKeyframe = false;
  else if (waitingForKeyframe) return;
  // Falling behind: skip ahead to the next keyframe instead of showing a stale picture.
  if (decoder.decodeQueueSize > 8) {
    waitingForKeyframe = true;
    send({ t: 'kf' });
    return;
  }
  const timestamp = chunkNumber++ * 1000;
  submitted.set(timestamp, performance.now());
  try {
    decoder.decode(new EncodedVideoChunk({ type: isKeyframe ? 'key' : 'delta', timestamp, data }));
  } catch (error) {
    send({ t: 'log', m: 'decode refused, ' + (error.message || error) });
    waitingForKeyframe = true;
    send({ t: 'kf' });
  }
}

function show(frame) {
  const width = frame.displayWidth, height = frame.displayHeight;
  if (screenCanvas.width !== width || screenCanvas.height !== height) {
    screenCanvas.width = width;
    screenCanvas.height = height;
    layout();
  }
  picture.drawImage(frame, 0, 0, width, height);
  const sent = submitted.get(frame.timestamp);
  if (sent !== undefined) { stats.delays.push(performance.now() - sent); submitted.delete(frame.timestamp); }
  frame.close();
  stats.frames++;
  decoderErrors = 0;
  if (!hasVideo) {
    hasVideo = true;
    send({ t: 'first' });
    screenCanvas.style.display = 'block';
    $('keyboard').style.display = 'block';
    hideStatus();
    layout();
  }
}

setInterval(() => {
  if (!socket || !hasVideo) return;
  const delays = stats.delays.sort((a, b) => a - b);
  send({
    t: 'stats', fps: stats.frames / 2, decodeMs: delays.length ? Math.round(delays[delays.length >> 1] * 10) / 10 : null,
    worstMs: delays.length ? Math.round(delays[delays.length - 1]) : null,
    queue: decoder ? decoder.decodeQueueSize : null, picture: screenCanvas.width + 'x' + screenCanvas.height,
  });
  stats.frames = 0;
  stats.delays = [];
}, 2000);

// ------------------------------------------------------------------- Layout

let rect = { left: 0, top: 0, width: 0, height: 0 };
let sentSize = null, resizeTimer = null;

// The size of the page, which the Mac's virtual display is made to match.
// The on-screen keyboard does not change it.
function viewportSize() {
  return { w: window.innerWidth, h: window.innerHeight, dpr: window.devicePixelRatio || 1 };
}

function layout() {
  // The visible part of the page: smaller than the page while the keyboard is up.
  const viewport = window.visualViewport;
  const box = viewport
    ? { left: viewport.offsetLeft, top: viewport.offsetTop, width: viewport.width, height: viewport.height }
    : { left: 0, top: 0, width: window.innerWidth, height: window.innerHeight };
  const typingNow = document.activeElement === typing;
  const keysHeight = typingNow ? 48 : 0;

  stage.style.left = box.left + 'px';
  stage.style.top = box.top + 'px';
  stage.style.width = box.width + 'px';
  stage.style.height = (box.height - keysHeight) + 'px';
  $('keys').style.display = typingNow ? 'flex' : 'none';
  $('keys').style.top = (box.top + box.height - keysHeight) + 'px';
  $('keyboard').style.top = (box.top + box.height - keysHeight - 56) + 'px';
  $('keyboard').style.right = (window.innerWidth - box.left - box.width + 10) + 'px';

  const width = screenCanvas.width, height = screenCanvas.height;
  if (!hasVideo || !width || !height) return;
  const scale = Math.min(box.width / width, (box.height - keysHeight) / height);
  rect = {
    width: width * scale, height: height * scale,
    left: (box.width - width * scale) / 2, top: (box.height - keysHeight - height * scale) / 2,
  };
  screenCanvas.style.left = rect.left + 'px';
  screenCanvas.style.top = rect.top + 'px';
  screenCanvas.style.width = rect.width + 'px';
  screenCanvas.style.height = rect.height + 'px';
  placeCursor();
}

function viewportChanged() {
  layout();
  clearTimeout(resizeTimer);
  resizeTimer = setTimeout(() => {
    const size = viewportSize();
    if (!sentSize || (size.w === sentSize.w && size.h === sentSize.h)) return;
    sentSize = size;
    send({ t: 'resize', ...size });
  }, 500);
}
window.addEventListener('resize', viewportChanged);
if (window.visualViewport) {
  visualViewport.addEventListener('resize', layout);
  visualViewport.addEventListener('scroll', layout);
}

// ------------------------------------------------------------------ Pointer

// Pointer coordinates are in the Mac's picture pixels.
let space = { w: 0, h: 0 };
const pointer = { x: 0, y: 0, placed: false };
let cursor = { w: 0, h: 0, hotX: 0, hotY: 0 };
let usingMouse = false;

function setSpace(width, height) {
  if (!pointer.placed) {
    pointer.placed = true;
    pointer.x = width / 2;
    pointer.y = height / 2;
  } else if (space.w && space.h) {
    pointer.x *= width / space.w;
    pointer.y *= height / space.h;
  }
  space = { w: width, h: height };
  sendPointer(0);
  placeCursor();
}

function sendPointer(buttons) {
  if (!space.w) return;
  send({ t: 'p', x: Math.round(pointer.x), y: Math.round(pointer.y), b: buttons });
}

function setCursor(width, height, hotX, hotY, rgba) {
  if (!width || !height || rgba.length < width * height * 4) return;
  cursorCanvas.width = width;
  cursorCanvas.height = height;
  cursorCanvas.getContext('2d').putImageData(new ImageData(new Uint8ClampedArray(rgba.slice(0, width * height * 4)), width, height), 0, 0);
  cursor = { w: width, h: height, hotX, hotY };
  placeCursor();
}

// Until the Mac says what its pointer looks like, draw a plain arrow.
(function defaultCursor() {
  cursorCanvas.width = 24;
  cursorCanvas.height = 36;
  const context = cursorCanvas.getContext('2d');
  context.beginPath();
  context.moveTo(2, 2); context.lineTo(2, 30); context.lineTo(9, 23); context.lineTo(14, 34);
  context.lineTo(18, 32); context.lineTo(13, 21); context.lineTo(22, 21); context.closePath();
  context.fillStyle = '#000'; context.fill();
  context.lineWidth = 2; context.strokeStyle = '#fff'; context.stroke();
  cursor = { w: 24, h: 36, hotX: 2, hotY: 2 };
})();

function placeCursor() {
  if (!hasVideo || !space.w || !rect.width) { cursorCanvas.style.display = 'none'; return; }
  // Touch screens get a larger pointer: a true-size one is hard to spot on a small screen.
  const scale = rect.width / space.w * (usingMouse ? 1 : 1.5);
  const x = rect.left + pointer.x * rect.width / space.w - cursor.hotX * scale;
  const y = rect.top + pointer.y * rect.height / space.h - cursor.hotY * scale;
  cursorCanvas.style.display = 'block';
  cursorCanvas.style.transform = 'translate(' + x + 'px,' + y + 'px) scale(' + scale + ')';
}

// Mouse: the pointer goes where the mouse is.
function mouseEvent(event) {
  if (!rect.width || !space.w) return;
  if (!usingMouse) { usingMouse = true; screenCanvas.classList.add('mouse'); }
  const box = stage.getBoundingClientRect();
  pointer.x = clamp((event.clientX - box.left - rect.left) / rect.width * space.w, 0, space.w - 1);
  pointer.y = clamp((event.clientY - box.top - rect.top) / rect.height * space.h, 0, space.h - 1);
  sendPointer(event.buttons & 7);
  placeCursor();
}

// Touch: the screen is a trackpad, so a finger never covers what it points at.
//   one finger slides the pointer, a tap clicks, touch-and-hold then slide drags;
//   two fingers scroll, a two-finger tap right-clicks;
//   three fingers swipe to Mission Control, the app's windows, and between Spaces.
const fingers = new Map();
let gesture = null;
let wheelRemainder = 0;

function click(button) { sendPointer(button); sendPointer(0); }

function scrollBy(distance) {
  gesture.scroll += distance;
  const step = 12;   // one wheel step for every 12 points of travel
  while (Math.abs(gesture.scroll) >= step) {
    click(gesture.scroll > 0 ? Button.scrollUp : Button.scrollDown);
    gesture.scroll += gesture.scroll > 0 ? -step : step;
  }
}

function touchDown(event) {
  if (usingMouse) { usingMouse = false; screenCanvas.classList.remove('mouse'); }
  fingers.set(event.pointerId, { x: event.clientX, y: event.clientY, time: event.timeStamp });
  if (!gesture) gesture = { start: event.timeStamp, count: 0, travel: 0, dragging: false, hold: null, scroll: 0, swipeX: 0, swipeY: 0, swiped: false };
  gesture.count = Math.max(gesture.count, fingers.size);
  clearTimeout(gesture.hold);
  if (gesture.count === 1) {
    const mine = gesture;
    gesture.hold = setTimeout(() => {
      if (gesture !== mine || mine.count !== 1 || mine.travel >= 10 || fingers.size !== 1) return;
      mine.dragging = true;
      sendPointer(Button.left);
    }, 350);
  } else if (gesture.dragging) {
    gesture.dragging = false;
    sendPointer(0);
  }
}

function touchMove(event) {
  const finger = fingers.get(event.pointerId);
  if (!finger || !gesture) return;
  const dx = event.clientX - finger.x, dy = event.clientY - finger.y;
  const elapsed = Math.max(event.timeStamp - finger.time, 1);
  finger.x = event.clientX; finger.y = event.clientY; finger.time = event.timeStamp;
  const distance = Math.hypot(dx, dy);
  const before = gesture.travel;
  gesture.travel += distance / Math.max(fingers.size, 1);

  if (gesture.count === 1) {
    // Ignore the first few points so a tap does not nudge the pointer.
    if (!gesture.dragging && before < 6) return;
    if (!rect.width || !space.w) return;
    // Slow movement is scaled down for precision, fast movement up for reach.
    const speed = distance / elapsed * 1000;
    const gain = (space.w / rect.width) * clamp(0.5 + speed / 700, 0.5, 2.5);
    pointer.x = clamp(pointer.x + dx * gain, 0, space.w - 1);
    pointer.y = clamp(pointer.y + dy * gain, 0, space.h - 1);
    sendPointer(gesture.dragging ? Button.left : 0);
    placeCursor();
  } else if (gesture.count === 2) {
    if (gesture.travel > 8) scrollBy(dy / 2);
  } else if (gesture.count === 3 && !gesture.swiped) {
    gesture.swipeX += dx / 3;
    gesture.swipeY += dy / 3;
    if (Math.hypot(gesture.swipeX, gesture.swipeY) < 40) return;
    gesture.swiped = true;
    if (Math.abs(gesture.swipeY) > Math.abs(gesture.swipeX)) chord([Key.control], gesture.swipeY < 0 ? Key.up : Key.down);
    else chord([Key.control], gesture.swipeX < 0 ? Key.right : Key.left);
  }
}

function touchUp(event) {
  if (!fingers.delete(event.pointerId) || !gesture || fingers.size > 0) return;
  const finished = gesture;
  gesture = null;
  clearTimeout(finished.hold);
  const duration = event.timeStamp - finished.start;
  if (finished.dragging) sendPointer(0);
  else if (event.type === 'pointercancel') return;
  else if (finished.count === 1 && finished.travel < 10 && duration < 350) click(Button.left);
  else if (finished.count === 2 && finished.travel < 12 && duration < 400) click(Button.right);
}

stage.addEventListener('pointerdown', event => {
  event.preventDefault();
  try { stage.setPointerCapture(event.pointerId); } catch (e) {}
  if (event.pointerType === 'mouse') mouseEvent(event); else touchDown(event);
});
stage.addEventListener('pointermove', event => {
  if (event.pointerType === 'mouse') mouseEvent(event); else touchMove(event);
});
for (const type of ['pointerup', 'pointercancel']) {
  stage.addEventListener(type, event => {
    if (event.pointerType === 'mouse') mouseEvent(event); else touchUp(event);
  });
}
stage.addEventListener('wheel', event => {
  event.preventDefault();
  if (!space.w) return;
  wheelRemainder += event.deltaY * (event.deltaMode === 1 ? 16 : 1);
  const step = 24;
  while (Math.abs(wheelRemainder) >= step) {
    click(wheelRemainder > 0 ? Button.scrollDown : Button.scrollUp);
    wheelRemainder += wheelRemainder > 0 ? -step : step;
  }
}, { passive: false });
stage.addEventListener('contextmenu', event => event.preventDefault());
// Safari's own pinch and double-tap zoom.
for (const type of ['gesturestart', 'gesturechange', 'gestureend']) {
  document.addEventListener(type, event => event.preventDefault());
}
document.addEventListener('touchmove', event => { if (event.target === stage || stage.contains(event.target)) event.preventDefault(); }, { passive: false });

// ----------------------------------------------------------------- Keyboard

const named = {
  Enter: Key.enter, Backspace: Key.backspace, Tab: Key.tab, Escape: Key.escape, Delete: Key.delete,
  ArrowLeft: Key.left, ArrowUp: Key.up, ArrowRight: Key.right, ArrowDown: Key.down,
  Home: 0xFF50, End: 0xFF57, PageUp: 0xFF55, PageDown: 0xFF56, ' ': 0x20, Spacebar: 0x20,
};
const sided = { Shift: [0xFFE1, 0xFFE2], Control: [0xFFE3, 0xFFE4], Alt: [0xFFE9, 0xFFEA], Meta: [0xFFEB, 0xFFEC] };

function keysymForCharacter(character) {
  const point = character.codePointAt(0);
  if (point === 0x0A || point === 0x0D) return Key.enter;
  if (point === 0x09) return Key.tab;
  if ((point >= 0x20 && point <= 0x7E) || (point >= 0xA0 && point <= 0xFF)) return point;   // Latin-1 maps directly
  return (0x01000000 | point) >>> 0;
}

function keysymForEvent(event) {
  if (sided[event.key]) return sided[event.key][event.location === 2 ? 1 : 0];
  if (named[event.key] !== undefined) return named[event.key];
  const functionKey = /^F(\d{1,2})$/.exec(event.key);
  if (functionKey && functionKey[1] >= 1 && functionKey[1] <= 12) return 0xFFBE + Number(functionKey[1]) - 1;
  // With Option, Control or Command held the browser reports the modified
  // character; the Mac wants the key itself.
  if (event.altKey || event.ctrlKey || event.metaKey) {
    const letter = /^Key([A-Z])$/.exec(event.code || '');
    if (letter) return letter[1].toLowerCase().charCodeAt(0);
    const digit = /^Digit(\d)$/.exec(event.code || '');
    if (digit) return digit[1].charCodeAt(0);
  }
  if (event.key && Array.from(event.key).length === 1) return keysymForCharacter(event.key);
  return null;
}

function key(keysym, down) { send({ t: 'k', k: keysym, d: down }); }
function chord(modifiers, keysym) {
  modifiers.forEach(m => key(m, true));
  key(keysym, true);
  key(keysym, false);
  modifiers.slice().reverse().forEach(m => key(m, false));
}

// Modifiers latched from the key bar apply to the next key, then let go.
const latched = new Set();
function tap(keysym) {
  chord(Array.from(latched), keysym);
  if (latched.size) {
    latched.clear();
    document.querySelectorAll('#keys button.held').forEach(button => button.classList.remove('held'));
  }
}

const held = new Map();   // physical key -> keysym sent for it
function releaseEverything() {
  held.forEach(keysym => key(keysym, false));
  held.clear();
}

document.addEventListener('keydown', event => {
  if (!socket || !hasVideo || event.isComposing) return;
  const keysym = keysymForEvent(event);
  if (keysym === null) return;   // dictation, autocorrect and the like arrive as text instead
  event.preventDefault();
  const physical = event.code && event.code !== 'Unidentified';
  // On-screen keyboards do not report reliable releases, so their keys are taps.
  if (!physical || latched.size) { if (!sided[event.key]) tap(keysym); return; }
  if (!held.has(event.code)) held.set(event.code, keysym);
  key(held.get(event.code), true);
});
document.addEventListener('keyup', event => {
  const keysym = held.get(event.code);
  if (keysym === undefined) return;
  held.delete(event.code);
  key(keysym, false);
  // macOS browsers do not report releases of other keys while Command is down.
  if (event.key === 'Meta') releaseEverything();
});
window.addEventListener('blur', releaseEverything);

// Text that arrives without key events.
typing.addEventListener('input', event => {
  const text = event.data || typing.value;
  typing.value = '';
  if (event.inputType === 'deleteContentBackward') { tap(Key.backspace); return; }
  if (event.inputType === 'insertLineBreak') { tap(Key.enter); return; }
  if (!text || event.isComposing) return;
  for (const character of text) tap(keysymForCharacter(character));
});
typing.addEventListener('focus', layout);
typing.addEventListener('blur', layout);

$('keyboard').addEventListener('pointerdown', event => {
  event.preventDefault();
  if (document.activeElement === typing) typing.blur(); else typing.focus({ preventScroll: true });
});
$('keys').addEventListener('pointerdown', event => {
  const button = event.target.closest('button');
  if (!button) return;
  event.preventDefault();   // keep the keyboard up
  if (button.dataset.modifier) {
    const modifier = Number(button.dataset.modifier);
    if (latched.has(modifier)) latched.delete(modifier); else latched.add(modifier);
    button.classList.toggle('held', latched.has(modifier));
  } else {
    tap(Number(button.dataset.key));
  }
});

window.addEventListener('pagehide', () => { if (socket) socket.close(); });

layout();
connect();
</script>
</body>
</html>
"""#
}
