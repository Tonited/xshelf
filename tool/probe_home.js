// dump 首页 HTML 结构，搞清为什么抓不到 client-web JS bundle。
const fs = require('fs');
const http = require('http');
const tls = require('tls');
const path = require('path');

const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PROXY_PORT = Number(process.env.PROXY_PORT || 7897);
const UA =
  'Mozilla/5.0 (Windows NT 10.0; Win64; x64) AppleWebKit/537.36 (KHTML, like Gecko) Chrome/141.0.0.0 Safari/537.36';
const cookies = JSON.parse(fs.readFileSync(path.join(OUT, 'cookies.json'), 'utf8'));

function tunnel(host, port = 443) {
  return new Promise((resolve, reject) => {
    const req = http.request({ host: '127.0.0.1', port: PROXY_PORT, method: 'CONNECT', path: `${host}:${port}` });
    req.on('connect', (res, socket) => {
      if (res.statusCode !== 200) return reject(new Error('CONNECT ' + res.statusCode));
      const t = tls.connect({ socket, servername: host }, () => resolve(t));
      t.on('error', reject);
    });
    req.on('error', reject);
    req.end();
  });
}

async function get(host, p, headers) {
  const socket = await tunnel(host);
  const lines = [
    `GET ${p} HTTP/1.1`, `Host: ${host}`,
    ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
    'connection: close', 'accept-encoding: identity',
  ];
  socket.write(lines.join('\r\n') + '\r\n\r\n');
  let raw = '';
  return await new Promise((resolve, reject) => {
    socket.on('data', (d) => (raw += d.toString('utf8')));
    socket.on('end', () => {
      const idx = raw.indexOf('\r\n\r\n');
      const head = raw.slice(0, idx).split('\r\n');
      resolve({ status: Number(head[0].split(' ')[1]), head, body: raw.slice(idx + 4) });
    });
    socket.on('error', reject);
    setTimeout(() => reject(new Error('timeout')), 25000);
  });
}

(async () => {
  const authed = {
    'user-agent': UA,
    'accept-language': 'en-US,en;q=0.9',
    accept: 'text/html,application/xhtml+xml',
    cookie: `auth_token=${cookies.auth_token}; ct0=${cookies.ct0}; twid=${cookies.twid}`,
  };
  const r = await get('x.com', '/home', authed);
  console.log('status:', r.status, '| body len:', r.body.length);
  fs.writeFileSync(path.join(OUT, 'home.html'), r.body);
  const allScripts = [...r.body.matchAll(/https?:\/\/[^"'\s>]+\.js/g)].map((m) => m[0]);
  console.log('js refs:', allScripts.length);
  console.log(allScripts.slice(0, 12).join('\n'));
  const scriptTags = [...r.body.matchAll(/<script[^>]*src=["']([^"']+)["']/g)].map((m) => m[1]);
  console.log('\nscript tags:', scriptTags.length);
  console.log(scriptTags.slice(0, 12).join('\n'));
  // 看看有什么 queryId / operationName 线索
  const ops = [...new Set([...r.body.matchAll(/operationName:"([A-Za-z]+)"/g)].map((m) => m[1]))];
  console.log('\noperationNames in html:', ops.slice(0, 20));
  console.log('\nhead of html:\n', r.body.slice(0, 800));
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
