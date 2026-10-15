// usage: HOST=<name>.<tailnet>.ts.net:8443 TOKEN_FILE=<path> node probe.js   (needs `ws` under $TMPDIR/node)
const WebSocket = require(process.env.TMPDIR + '/node/node_modules/ws');
const fs = require('fs'); const token = fs.readFileSync(process.env.TOKEN_FILE,'utf8').trim();
const run = (label, headers, protocols) => new Promise(res => {
  const ws = new WebSocket('wss://'+process.env.HOST+'/ws', protocols, { headers, perMessageDeflate:false });
  const msgs=[]; const to=setTimeout(()=>{ console.log(label,'-> TIMEOUT (no open/response in 8s), readyState',ws.readyState); try{ws.terminate()}catch{}; res(); },8000); ws.on('message',(d,b)=>{ if(!b) msgs.push(JSON.parse(d.toString())); });
  ws.on('open',()=>{ ws.send(JSON.stringify({type:'list'})); setTimeout(()=>{ console.log(label,'-> OPEN, msgs:',JSON.stringify(msgs).slice(0,160)); clearTimeout(to); ws.close(); res(); },800); });
  ws.on('unexpected-response',(rq,r)=>{ clearTimeout(to); console.log(label,'-> HTTP',r.statusCode); res(); });
  ws.on('error',e=>{ console.log(label,'-> error',e.message); res(); });
});
(async()=>{
  await run('valid token + browser-like Origin', {Origin:'https://'+process.env.HOST}, ['shepherd-v1','token.'+token]);
  await run('valid token, no Origin', {}, ['shepherd-v1','token.'+token]);
  await run('wrong token', {Origin:'https://'+process.env.HOST}, ['shepherd-v1','token.nope']);
  await run('foreign Origin', {Origin:'https://evil.example'}, ['shepherd-v1','token.'+token]);
})();
