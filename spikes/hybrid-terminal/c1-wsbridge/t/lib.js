const WebSocket = require(process.env.TMPDIR + '/node/node_modules/ws');
const { Terminal } = require(process.env.TMPDIR + '/node/node_modules/@xterm/headless');
const fs = require('fs'), path = require('path');
const STATE = path.join(__dirname, 'state');
const TOKEN = () => fs.readFileSync(path.join(STATE, 'token'), 'utf8').trim();
const PORT = 18750;
const sleep = ms => new Promise(r => setTimeout(r, ms));

class Client {
  constructor(name, { cols = 100, rows = 30, origin, host, token, protocols } = {}) {
    this.name = name; this.cols = cols; this.rows = rows; this.msgs = []; this.bytes = 0; this.closed = null;
    this.term = new Terminal({ cols, rows, allowProposedApi: true, scrollback: 2000 });
    this.opts = { origin, host, token, protocols };
    this.waiters = [];
  }
  connect() {
    const headers = {};
    if (this.opts.origin) headers.Origin = this.opts.origin;
    if (this.opts.host) headers.Host = this.opts.host;
    const protocols = this.opts.protocols || ['shepherd-v1', 'token.' + (this.opts.token ?? TOKEN())];
    this.ws = new WebSocket(`ws://127.0.0.1:${PORT}/ws`, protocols, { headers, perMessageDeflate: false });
    this.ws.on('message', (d, bin) => {
      if (bin) { this.bytes += d.length; this.term.write(d); }
      else { const m = JSON.parse(d.toString()); this.msgs.push(m); if (m.type === 'size' || m.type === 'attached') this.term.resize(m.cols, m.rows); if (m.type === 'hello') this.id = m.you; }
      this.waiters = this.waiters.filter(w => !w());
    });
    this.ws.on('close', (c, r) => { this.closed = { code: c, reason: r.toString() }; });
    this.ws.on('error', e => { this.error = e.message; });
    return new Promise(res => { this.ws.once('open', () => res(true)); this.ws.once('error', () => res(false)); this.ws.once('unexpected-response', (rq, resp) => { this.httpStatus = resp.statusCode; res(false); }); });
  }
  send(o) { this.ws.send(JSON.stringify(o)); }
  input(s) { this.ws.send(Buffer.from(s)); }
  last(type) { return [...this.msgs].reverse().find(m => m.type === type); }
  async until(pred, ms = 10000) {
    const t0 = Date.now();
    while (Date.now() - t0 < ms) { if (pred()) return true; await sleep(100); }
    return false;
  }
  screen() { // active buffer text, trailing blanks trimmed
    const b = this.term.buffer.active; const out = [];
    for (let i = 0; i < this.term.rows; i++) out.push((b.getLine(b.baseY + i)?.translateToString(true) ?? ''));
    return out;
  }
  text() { return this.screen().join('\n'); }
  async flush() { await new Promise(r => this.term.write('', r)); }
  async attach(id, cols = this.cols, rows = this.rows) {
    this.msgs = this.msgs.filter(m => m.type !== 'ready');
    this.send({ type: 'attach', id, cols, rows });
    const ok = await this.until(() => this.last('ready') || this.last('error'), 8000);
    await sleep(600); await this.flush();
    return ok;
  }
  close() { try { this.ws.close(); } catch {} }
  kill() { try { this.ws.terminate(); } catch {} }
}
function diff(a, b) {
  const out = []; const n = Math.max(a.length, b.length);
  for (let i = 0; i < n; i++) if ((a[i] ?? '') !== (b[i] ?? '')) out.push(`  row ${i}:\n    A|${a[i] ?? ''}\n    B|${b[i] ?? ''}`);
  return out;
}
module.exports = { Client, sleep, diff, TOKEN, PORT, STATE };
