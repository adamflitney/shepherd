const { Client, sleep, diff } = require('./lib');
const cwd = require('path').join(__dirname, '..', 'work');
const show = (c, label) => console.log(`--- ${label} (${c.term.cols}x${c.term.rows}, ${c.bytes} bytes)\n` + c.screen().map(l => '|' + l).join('\n'));
(async () => {
  const A = new Client('A');
  console.log('A connect', await A.connect());
  A.send({ type: 'spawn', kind: 'claude', cwd, cols: 100, rows: 30 });
  await A.until(() => A.last('spawned') || A.last('error'));
  const id = (A.last('spawned') || {}).id; console.log('spawned', A.last('spawned') || A.last('error'));
  console.log('attach', await A.attach(id));
  await A.until(() => /trust|Welcome|\? for shortcuts/.test(A.text()), 20000); await sleep(1500); await A.flush();
  show(A, 'A after start');
  if (/trust/i.test(A.text())) { A.input('\x1b[B'); await sleep(300); A.input('\r'); await A.until(() => /shortcuts|bypass|Try /.test(A.text()), 25000); await sleep(1500); await A.flush(); show(A, 'A after trust answered'); }
  A.input('Reply with exactly the single word PINEAPPLE and nothing else.'); await sleep(300); A.input('\r');
  await A.until(() => (A.text().match(/PINEAPPLE/g) || []).length >= 2, 60000); await sleep(1500); await A.flush();
  show(A, 'A after reply');
  // resize
  A.send({ type: 'resize', cols: 120, rows: 35 });
  await A.until(() => A.last('size')?.cols === 120); await sleep(1500); await A.flush();
  console.log('size msg', A.last('size'));
  show(A, 'A after resize to 120x35');
  // B: never-disconnected observer joins now
  const B = new Client('B', { cols: 120, rows: 35 }); await B.connect();
  console.log('B attach', await B.attach(id, 120, 35));
  await sleep(1500); await B.flush(); await A.flush();
  console.log('B vs A diff rows:', diff(A.screen(), B.screen()).length); diff(A.screen(), B.screen()).forEach(l => console.log(l));
  // A drops hard and reconnects as A2; compare with B (B never disconnected)
  A.kill(); await sleep(500);
  const A2 = new Client('A2', { cols: 120, rows: 35 }); await A2.connect();
  console.log('A2 attach (replay ' + 'n/a' + ')', await A2.attach(id, 120, 35));
  console.log('A2 attached msg', A2.last('attached'));
  await sleep(2500); await A2.flush(); await B.flush();
  const d = diff(B.screen(), A2.screen());
  console.log('A2 vs B(never disconnected) differing rows:', d.length); d.slice(0, 8).forEach(l => console.log(l));
  show(A2, 'A2 after reconnect');
  console.log('A2 buffer type:', A2.term.buffer.active.type, ' B buffer type:', B.term.buffer.active.type);
  // typing from the reconnected client still works
  A2.input('/exit'); await sleep(400); A2.input('\r'); await sleep(2500);
  const L = await (async () => { B.send({ type: 'list' }); await B.until(() => B.last('sessions')); return B.last('sessions'); })();
  console.log('sessions after /exit:', JSON.stringify(L.sessions.map(s => ({ id: s.id, alive: s.alive }))));
  B.close(); A2.close(); process.exit(0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
