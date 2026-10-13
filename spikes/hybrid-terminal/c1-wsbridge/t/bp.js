const net = require('net'), crypto = require('crypto'), { execSync } = require('child_process');
const WebSocket = require(process.env.TMPDIR + '/node/node_modules/ws');
const { TOKEN, PORT, sleep } = require('./lib');
const path = require('path'); const work = path.join(__dirname, '..', 'work'); const STATE = path.join(__dirname, 'state');
const rss = name => { try { return Math.round(+execSync(`ps -o rss= -p $(pgrep -f '${name}' | head -1)`).toString().trim() / 1024); } catch { return -1; } };
const cpu = name => { try { return execSync(`ps -o %cpu= -p $(pgrep -f '${name}' | head -1)`).toString().trim(); } catch { return '?'; } };
function mask(op, payload) { const mk = crypto.randomBytes(4); const b = Buffer.from(payload); for (let i = 0; i < b.length; i++) b[i] ^= mk[i & 3]; const h = b.length < 126 ? Buffer.from([0x80 | op, 0x80 | b.length]) : Buffer.from([0x80 | op, 0x80 | 126, b.length >> 8, b.length & 255]); return Buffer.concat([h, mk, b]); }
(async () => {
  const label = process.argv[2] || 'run';
  // fast client: counts bytes, never parses
  const F = new WebSocket(`ws://127.0.0.1:${PORT}/ws`, ['shepherd-v1', 'token.' + TOKEN()], { perMessageDeflate: false });
  let fbytes = 0, msgs = [], fclosed = null, fresets = 0;
  F.on('message', (d, bin) => { if (bin) fbytes += d.length; else { const m = JSON.parse(d.toString()); if (m.type === 'reset') fresets++; else msgs.push(m); } });
  F.on('close', (c) => fclosed = c);
  await new Promise(r => F.once('open', r));
  F.send(JSON.stringify({ type: 'spawn', kind: 'shell', script: "yes 'the quick brown fox jumps over the lazy dog 0123456789 the quick brown fox'", cwd: work, cols: 100, rows: 30 }));
  while (!msgs.find(m => m.type === 'spawned')) await sleep(50);
  const id = msgs.find(m => m.type === 'spawned').id;
  // slow client: raw TCP, handshake, attach, then stop reading entirely
  const S = net.connect(PORT, '127.0.0.1'); let sclosed = false, sgot = 0; S.on('close', () => sclosed = true); S.on('error', () => {});
  await new Promise(r => S.once('connect', r));
  S.write(`GET /ws HTTP/1.1\r\nHost: 127.0.0.1:${PORT}\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${crypto.randomBytes(16).toString('base64')}\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: shepherd-v1, token.${TOKEN()}\r\n\r\n`);
  await sleep(300);
  S.on('data', d => sgot += d.length);
  S.write(mask(1, JSON.stringify({ type: 'attach', id, cols: 100, rows: 30 })));
  await sleep(300);
  S.pause(); // from now on the slow client reads nothing
  F.send(JSON.stringify({ type: 'attach', id, cols: 100, rows: 30 }));
  await sleep(500);
  console.log(`[${label}] t=0  bridge RSS ${rss('wsbridge --port')} MB, holder RSS ${rss('ptyd daemon')} MB`);
  let last = fbytes;
  for (let t = 2; t <= 14; t += 2) {
    await sleep(2000);
    const t0 = Date.now(); F.send(JSON.stringify({ type: 'list' }));
    const listed = await new Promise(r => { const iv = setInterval(() => { const m = msgs.filter(x => x.type === 'sessions'); if (m.length) { clearInterval(iv); msgs = msgs.filter(x => x.type !== 'sessions'); r(Date.now() - t0); } if (Date.now() - t0 > 5000) { clearInterval(iv); r(-1); } }, 20); });
    console.log(`[${label}] t=${String(t).padStart(2)}s bridge RSS ${String(rss('wsbridge --port')).padStart(5)} MB cpu ${cpu('wsbridge --port')}%, holder RSS ${rss('ptyd daemon')} MB cpu ${cpu('ptyd daemon')}%, fast client ${((fbytes - last) / 2e6).toFixed(1)} MB/s, list latency ${listed} ms, slow client ${sclosed ? 'DROPPED' : 'connected'}`);
    last = fbytes;
  }
  console.log(`[${label}] slow client received ${sgot} bytes before stalling; fast client total ${(fbytes / 1e6).toFixed(0)} MB, resets ${fresets}; fast client closed? ${fclosed}`);
  process.exit(0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
