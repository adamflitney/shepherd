const { Client, sleep, diff } = require('./lib'); const path = require('path'); const work = path.join(__dirname, '..', 'work');
(async () => {
  const B = new Client('B', { cols: 100, rows: 30 }); await B.connect();
  B.send({ type: 'spawn', kind: 'shell', script: `python3 ${path.join(__dirname, 'tui.py')}`, cwd: work, cols: 100, rows: 30 });
  await B.until(() => B.last('spawned')); const id = B.last('spawned').id;
  await B.attach(id, 100, 30);
  console.log('waiting until the 512 KB ring has wrapped (alt-screen entry long gone)...');
  await sleep(9000);
  B.send({ type: 'list' }); await B.until(() => B.last('sessions')); console.log('ring bytes:', B.last('sessions').sessions[0].ring, ' B received', B.bytes, 'bytes total');
  B.msgs = [];
  const A2 = new Client('A2', { cols: 100, rows: 30 }); await A2.connect();
  await A2.attach(id, 100, 30);
  console.log('A2 attached msg:', JSON.stringify(A2.last('attached')));
  await sleep(1500); await A2.flush(); await B.flush();
  const frameLine = c => c.screen().find(l => /frame \d+ size/.test(l));
  console.log('buffer types: B', B.term.buffer.active.type, ' A2', A2.term.buffer.active.type);
  console.log('B  last row:', frameLine(B)); console.log('A2 last row:', frameLine(A2));
  // compare everything except the live frame counter row
  const strip = c => c.screen().map(l => l.replace(/frame \d+/, 'frame N'));
  const d = diff(strip(B), strip(A2));
  console.log('rows differing between never-disconnected B and reconnected A2 (frame counter masked):', d.length); d.slice(0, 6).forEach(x => console.log(x));
  const m = c => JSON.stringify({ bracketedPaste: c.term.modes.bracketedPasteMode, mouse: c.term.modes.mouseTrackingMode, focusEvents: c.term.modes.sendFocusMode, altScreen: c.term.buffer.active.type });
  console.log('modes B :', m(B)); console.log('modes A2:', m(A2));
  console.log('A2 scrollback lines (should be 0 for a clean alt screen):', A2.term.buffer.normal.length - A2.term.rows);
  process.exit(0);
})().catch(e => { console.error('FAIL', e); process.exit(1); });
