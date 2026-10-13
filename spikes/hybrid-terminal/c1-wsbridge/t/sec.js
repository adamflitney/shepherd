const net = require('net'), crypto = require('crypto'), { execSync } = require('child_process');
const { Client, sleep, TOKEN, PORT } = require('./lib');
const fs = require('fs'), path = require('path');
const work = path.join(__dirname, '..', 'work');
const rows = [];
const rec = (attack, outcome) => { rows.push([attack, outcome]); console.log(`${attack.padEnd(58)} -> ${outcome}`); };
const bridgePid = () => execSync("pgrep -f 'wsbridge --port'").toString().trim();
const PID0 = bridgePid();

function rawHTTP(text, { wait = 1500, binary } = {}) {
  return new Promise(res => {
    const s = net.connect(PORT, '127.0.0.1'); let buf = Buffer.alloc(0); let closed = false;
    s.on('data', d => buf = Buffer.concat([buf, d])); s.on('close', () => { closed = true; });
    s.on('error', () => {});
    s.on('connect', () => s.write(binary ?? text));
    setTimeout(() => { const t = buf.toString('latin1'); const m = t.match(/^HTTP\/1.1 (\d+)/); res({ status: m ? +m[1] : null, closed, buf, text: t, s }); }, wait);
  });
}
const key = () => crypto.randomBytes(16).toString('base64');
function upgradeReq({ host = `127.0.0.1:${PORT}`, origin, token = TOKEN(), extra = '', protocols, path = '/ws', version = '13', k = key(), dupHost } = {}) {
  const pr = protocols ?? `shepherd-v1, token.${token}`;
  return `GET ${path} HTTP/1.1\r\nHost: ${host}\r\n${dupHost ? `Host: ${dupHost}\r\n` : ''}${origin ? `Origin: ${origin}\r\n` : ''}Upgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: ${k}\r\nSec-WebSocket-Version: ${version}\r\nSec-WebSocket-Protocol: ${pr}\r\n${extra}\r\n`;
}
function frame({ fin = true, op = 1, payload = Buffer.alloc(0), mask = true, rsv = 0, declared } = {}) {
  const len = declared ?? payload.length; const h = [(fin ? 0x80 : 0) | (rsv << 4) | op];
  const mb = mask ? 0x80 : 0;
  let hdr;
  if (len < 126) hdr = Buffer.from([...h, mb | len]);
  else if (len < 65536) hdr = Buffer.from([...h, mb | 126, len >> 8, len & 255]);
  else { hdr = Buffer.alloc(10); hdr[0] = h[0]; hdr[1] = mb | 127; hdr.writeBigUInt64BE(BigInt(len), 2); }
  if (!mask) return Buffer.concat([hdr, payload]);
  const mk = crypto.randomBytes(4); const body = Buffer.from(payload); for (let i = 0; i < body.length; i++) body[i] ^= mk[i & 3];
  return Buffer.concat([hdr, mk, body]);
}
// open an authenticated raw ws; returns {s, closeInfo()}
async function rawWS() {
  const r = await rawHTTP(upgradeReq(), { wait: 400 });
  if (r.status !== 101) throw new Error('raw ws upgrade failed ' + r.status);
  const st = { buf: r.buf.subarray(r.buf.indexOf('\r\n\r\n') + 4), closed: false };
  r.s.removeAllListeners('data'); r.s.on('data', d => st.buf = Buffer.concat([st.buf, d])); r.s.on('close', () => st.closed = true);
  st.s = r.s;
  st.closeCode = () => { // scan server frames for a close frame
    let b = st.buf, i = 0;
    while (i + 2 <= b.length) {
      const op = b[i] & 15; let len = b[i + 1] & 127, h = 2;
      if (len === 126) { len = b.readUInt16BE(i + 2); h = 4 } else if (len === 127) { len = Number(b.readBigUInt64BE(i + 2)); h = 10 }
      if (i + h + len > b.length) break;
      if (op === 8) return len >= 2 ? b.readUInt16BE(i + h) : 1005;
      i += h + len;
    }
    return null;
  };
  return st;
}
async function alive(label) {
  const c = new Client('probe'); const ok = await c.connect();
  let listed = false;
  if (ok) { c.send({ type: 'list' }); listed = await c.until(() => c.last('sessions'), 3000); c.close(); }
  const same = bridgePid() === PID0;
  if (!(ok && listed && same)) { console.log(`  !! server unhealthy after ${label}: connect=${ok} list=${listed} samePid=${same}`); rows.push(['HEALTH after ' + label, 'UNHEALTHY']); }
}

(async () => {
  const H = `127.0.0.1:${PORT}`;
  // ---- handshake-level
  let r;
  r = await rawHTTP(upgradeReq({ host: 'evil.example' })); rec('DNS rebinding: Host: evil.example (valid token)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'https://evil.example' })); rec('cross-site WS hijack: Origin evil.example (valid token)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'null' })); rec('Origin: null (sandboxed iframe / file://)', r.status);
  r = await rawHTTP(upgradeReq({ origin: `http://127.0.0.1:${PORT}` })); rec('same-origin Origin + valid token (control: allowed)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'http://localhost:9999' })); rec('Origin localhost:9999 vs Host 127.0.0.1 (host differs)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'http://127.0.0.1:9999' })); rec('Origin 127.0.0.1:9999 (same host, other port)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'https://127.0.0.1:18750' })); rec('Origin https://127.0.0.1:18750 (scheme differs: port 443 vs 18750)', r.status);
  r = await rawHTTP(upgradeReq({ origin: 'ftp://127.0.0.1:18750' })); rec('Origin with non-http scheme', r.status);
  r = await rawHTTP(upgradeReq({ extra: 'Sec-Fetch-Site: cross-site\r\n' })); rec('Sec-Fetch-Site: cross-site', r.status);
  r = await rawHTTP(upgradeReq({ token: '' , protocols: 'shepherd-v1' })); rec('no token', r.status);
  r = await rawHTTP(upgradeReq({ token: 'wrong' })); rec('wrong token', r.status);
  r = await rawHTTP(upgradeReq({ token: TOKEN().slice(0, -1) })); rec('token one char short', r.status);
  r = await rawHTTP(upgradeReq({ token: TOKEN(), path: `/ws?token=${TOKEN()}`, protocols: 'shepherd-v1' })); rec('token only in URL query (not accepted)', r.status);
  r = await rawHTTP(upgradeReq({ protocols: `token.${TOKEN()}` })); rec('token but no shepherd-v1 subprotocol', r.status);
  r = await rawHTTP(upgradeReq({ extra: 'Tailscale-Funnel-Request: ?1\r\n' })); rec('Tailscale Funnel header', r.status);
  r = await rawHTTP(upgradeReq({ extra: 'Tailscale-User-Login: attacker@example.com\r\n' })); rec('forged Tailscale-User-Login (no owner configured)', r.status);
  r = await rawHTTP(upgradeReq({ extra: 'X-Forwarded-For: 100.1.2.3\r\n' })); rec('X-Forwarded-For without identity', r.status);
  r = await rawHTTP(upgradeReq({ dupHost: 'evil.example' })); rec('duplicate Host headers', r.status);
  r = await rawHTTP(upgradeReq({ version: '12' })); rec('Sec-WebSocket-Version 12', r.status);
  r = await rawHTTP(upgradeReq({ k: 'AAAA' })); rec('short Sec-WebSocket-Key', r.status);
  r = await rawHTTP(`GET /ws HTTP/1.1\r\nHost: ${H}\r\n\r\n`); rec('/ws without Upgrade headers', r.status);
  r = await rawHTTP(`POST /ws HTTP/1.1\r\nHost: ${H}\r\nContent-Length: 4\r\n\r\nabcd`); rec('POST with body', r.status);
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\nContent-Length: -1\r\n\r\n`); rec('Content-Length: -1 (the old crash)', r.status);
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\nContent-Length: 5\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n`); rec('CL + Transfer-Encoding (smuggling shape)', r.status);
  r = await rawHTTP(`\x00\x01garbage\r\n\r\n`); rec('binary garbage instead of HTTP', r.status ?? 'closed/no response');
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\nX-Pad: ${'a'.repeat(20000)}\r\n\r\n`); rec('20 KB header', r.status);
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\n` + `X-Pad: a\r\n`.repeat(3000) + '\r\n'); rec('3000 small headers (~30 KB)', r.status);
  r = await rawHTTP(`GET /${'a'.repeat(5000)} HTTP/1.1\r\nHost: ${H}\r\n\r\n`); rec('5 KB request target', r.status);
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\nBad\x01Header: x\r\n\r\n`); rec('control char in header', r.status);
  r = await rawHTTP(`GET /api/sessions HTTP/1.1\r\nHost: ${H}\r\n\r\n`); rec('/api/sessions without token', r.status);
  r = await rawHTTP(`GET /api/sessions HTTP/1.1\r\nHost: ${H}\r\nOrigin: https://evil.example\r\nAuthorization: Bearer ${TOKEN()}\r\n\r\n`); rec('/api/sessions cross-origin even with token', r.status);
  r = await rawHTTP(`GET / HTTP/1.1\r\nHost: ${H}\r\nX: y\r\n`, { wait: 6500 }); rec('slowloris: headers never finished (5 s timeout)', (r.status ?? 'no response') + (r.closed ? ' + socket closed' : ' (SOCKET STILL OPEN)'));
  const leak = [400, 403, 401].map(async st => { const q = await rawHTTP(st === 400 ? `GET /nope HTTP/1.1\r\nHost: ${H}\r\nContent-Length: -1\r\n\r\n` : st === 403 ? upgradeReq({ host: 'evil.example' }) : upgradeReq({ token: 'x' }), { wait: 2500 }); return q.closed; });
  rec('rejected requests (400/403/401) close their socket', (await Promise.all(leak)).every(Boolean) ? 'all closed within 2.5 s' : 'SOME LEFT OPEN');
  await alive('handshake attacks');

  // ---- connection flood
  const socks = []; for (let i = 0; i < 200; i++) { const s = net.connect(PORT, '127.0.0.1'); s.on('error', () => {}); socks.push(s); }
  await sleep(1500);
  const closedNow = socks.filter(s => s.destroyed || s.readyState !== 'open').length;
  rec('200 idle TCP connections at once (cap 64)', `${200 - closedNow} stayed open, ${closedNow} refused/closed`);
  const c1 = new Client('legit'); const okDuring = await c1.connect(); rec('legit client while flood holds slots', okDuring ? 'connected' : `refused (expected: cap reached; httpStatus ${c1.httpStatus ?? c1.error})`);
  socks.forEach(s => s.destroy()); await sleep(800);
  const c2 = new Client('legit2'); rec('legit client after flood released', (await c2.connect()) ? 'connected' : 'FAILED'); c2.close();
  await alive('connection flood');

  // ---- WS frame level
  const wsAttack = async (name, mk, expectClose = true, wait = 800) => {
    const w = await rawWS(); const t0 = Date.now();
    mk(w.s); await sleep(wait);
    const code = w.closeCode();
    rec(name, code ? `close ${code}${w.closed ? ' + socket closed' : ''}` : (w.closed ? 'socket closed, no close frame' : 'no close (connection kept)'));
    w.s.destroy();
  };
  await wsAttack('unmasked client frame', s => s.write(frame({ mask: false, payload: Buffer.from('{}') })));
  await wsAttack('RSV1 set (no extension negotiated)', s => s.write(frame({ rsv: 4, payload: Buffer.from('{}') })));
  await wsAttack('reserved opcode 3', s => s.write(frame({ op: 3 })));
  await wsAttack('fragmented ping', s => s.write(frame({ op: 9, fin: false })));
  await wsAttack('ping with 200-byte payload', s => s.write(frame({ op: 9, payload: Buffer.alloc(200) })));
  await wsAttack('continuation frame with nothing to continue', s => s.write(frame({ op: 0 })));
  await wsAttack('new data frame inside a fragmented message', s => { s.write(frame({ op: 1, fin: false, payload: Buffer.from('a') })); s.write(frame({ op: 1, payload: Buffer.from('b') })); });
  await wsAttack('declared 1 TiB payload, header only (no body sent)', s => s.write(frame({ op: 2, declared: 2 ** 40, payload: Buffer.alloc(0) }).subarray(0, 10 + 4)));
  await wsAttack('declared length with MSB set', s => { const b = Buffer.alloc(14); b[0] = 0x82; b[1] = 0xff; b.writeBigUInt64BE(1n << 63n, 2); s.write(b); });
  await wsAttack('300 KB binary frame (limit 256 KB)', s => s.write(frame({ op: 2, payload: Buffer.alloc(300 * 1024) })));
  await wsAttack('fragments adding up to 300 KB', s => { s.write(frame({ op: 2, fin: false, payload: Buffer.alloc(1024) })); for (let i = 0; i < 299; i++) s.write(frame({ op: 0, fin: false, payload: Buffer.alloc(1024) })); s.write(frame({ op: 0 })); });
  await wsAttack('invalid UTF-8 in a text frame', s => s.write(frame({ op: 1, payload: Buffer.from([0xff, 0xfe, 0x7b]) })));
  await wsAttack('20 KB JSON control message (limit 8 KB)', s => s.write(frame({ op: 1, payload: Buffer.from('{"type":"list","pad":"' + 'a'.repeat(20000) + '"}') })));
  await wsAttack('close frame with bogus payload', s => s.write(frame({ op: 8, payload: Buffer.from([0x03, 0xed]) })), true, 500);
  await wsAttack('truncated frame then silence (no hang for others)', s => s.write(frame({ op: 2, payload: Buffer.alloc(100) }).subarray(0, 20)), false, 500);
  await wsAttack('binary input while not attached', s => s.write(frame({ op: 2, payload: Buffer.from('ls\r') })), false, 500);
  await wsAttack('21 malformed JSON messages', s => { for (let i = 0; i < 21; i++) s.write(frame({ op: 1, payload: Buffer.from('not json') })); }, true, 1000);
  await wsAttack('control-message flood: 500 list messages in one write', s => s.write(Buffer.concat(Array.from({ length: 500 }, () => frame({ op: 1, payload: Buffer.from('{"type":"list"}') })))), true, 1500);
  const t0 = Date.now();
  await wsAttack('ping flood: 100000 pings in one write, never reading', s => s.write(Buffer.concat(Array.from({ length: 100000 }, () => frame({ op: 9, payload: Buffer.from('x') })))), true, 2500);
  console.log(`  (ping flood handled in ${Date.now() - t0 - 2500} ms over the wait)`);
  await alive('frame-level attacks');

  // ---- application-level validation (authenticated client)
  const A = new Client('app'); await A.connect();
  const ask = async (name, msg, pred) => { A.msgs = []; A.send(msg); await sleep(500); const m = A.msgs.find(pred) || A.msgs[0]; rec(name, m ? JSON.stringify(m).slice(0, 90) : 'no reply'); };
  fs.mkdirSync(path.join(work, 'sub'), { recursive: true });
  try { fs.unlinkSync(path.join(work, 'escape')); } catch {}
  fs.symlinkSync('/etc', path.join(work, 'escape'));
  await ask('spawn cwd=/etc', { type: 'spawn', kind: 'shell', script: 'id', cwd: '/etc' }, m => m.type === 'error');
  await ask('spawn cwd=<work>/../..  (traversal)', { type: 'spawn', kind: 'shell', script: 'id', cwd: work + '/../..' }, m => m.type === 'error');
  await ask('spawn cwd=<work>/escape -> /etc (symlink)', { type: 'spawn', kind: 'shell', script: 'id', cwd: path.join(work, 'escape') }, m => m.type === 'error');
  await ask('spawn kind=bash (unknown)', { type: 'spawn', kind: 'bash', cwd: work }, m => m.type === 'error');
  await ask('spawn cols=-1', { type: 'spawn', kind: 'claude', cwd: work, cols: -1, rows: 30 }, m => m.type === 'error');
  await ask('spawn cols=99999', { type: 'spawn', kind: 'claude', cwd: work, cols: 99999, rows: 30 }, m => m.type === 'error');
  await ask('attach id="../../etc/passwd"', { type: 'attach', id: '../../etc/passwd' }, m => m.type === 'error');
  await ask('attach nonexistent id', { type: 'attach', id: 'deadbeef' }, m => m.type === 'error');
  await ask('resize before attach', { type: 'resize', cols: 80, rows: 24 }, () => true);
  await ask('unknown message type', { type: 'rm -rf' }, m => m.type === 'error');
  fs.unlinkSync(path.join(work, 'escape')); A.close();
  await alive('application-level');
  fs.writeFileSync(path.join(__dirname, 'sec-result.json'), JSON.stringify(rows, null, 1));
  console.log('\nbridge pid unchanged:', bridgePid() === PID0, '| rows:', rows.length);
  process.exit(0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
