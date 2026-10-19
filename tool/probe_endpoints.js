// 探测 X 现行可用的「会话校验」端点（verify_credentials 已下线）。
const fs = require('fs');
const http = require('http');
const tls = require('tls');
const path = require('path');

const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PROXY_PORT = Number(process.env.PROXY_PORT || 7897);
const BEARER =
  'AAAAAAAAAAAAAAAAAAAAANRILgAAAAAAnNwIzUejRCOuH5E6I8xnZz4puTs%3D1Zv7ttfk8LF81IUq16cHjhLTvJu4FA33AGWWjCpTnA';
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

async function request(host, pathAndQuery, headers = {}, method = 'GET') {
  const socket = await tunnel(host);
  const lines = [
    `${method} ${pathAndQuery} HTTP/1.1`,
    `Host: ${host}`,
    ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
    'connection: close',
    'accept-encoding: identity',
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

const H = {
  authorization: 'Bearer ' + BEARER,
  'x-csrf-token': cookies.ct0,
  'x-twitter-auth-type': 'OAuth2Session',
  'x-twitter-active-user': 'yes',
  'x-twitter-client-language': 'en',
  accept: '*/*',
  'accept-language': 'en-US,en;q=0.9',
  referer: 'https://x.com/',
  'user-agent': UA,
  cookie: `auth_token=${cookies.auth_token}; ct0=${cookies.ct0}`,
};

const candidates = [
  '/i/api/1.1/account/settings.json?with_session_state=true',
  '/i/api/1.1/account/verify_credentials.json',
  '/i/api/1.1/users/show.json?skip_status=true',
  '/i/api/1.1/account/account_settings.json',
  '/i/api/2/account/settings.json',
];

(async () => {
  for (const p of candidates) {
    try {
      const r = await request('x.com', p, H);
      const snippet = r.body.replace(/\s+/g, ' ').slice(0, 160);
      console.log(`${r.status} ${p}\n     ${snippet}`);
    } catch (e) {
      console.log(`ERR ${p}: ${e.message}`);
    }
  }

  // 发现 GraphQL 的 Viewer（X 网页端用 Viewer 拿当前账号）
  console.log('\n=== discover Viewer / Likes queryId from client-web JS ===');
  const home = await request('x.com', '/', { 'user-agent': UA });
  const scripts = [...new Set((home.body.match(/https:\/\/abs\.twimg\.com\/responsive-web\/client-web[^"'\s]+\.js/g) || []))];
  console.log('scripts:', scripts.length);
  const found = {};
  for (const url of scripts.slice(0, 18)) {
    const u = new URL(url);
    try {
      const js = await request(u.host, u.pathname + u.search, { 'user-agent': UA });
      if (js.status !== 200) continue;
      for (const op of ['Viewer', 'Likes', 'UnfavoriteTweet', 'UserByScreenName']) {
        if (found[op]) continue;
        const m =
          js.body.match(new RegExp(`queryId:"([A-Za-z0-9_-]{10,})"[^}]{0,600}?operationName:"${op}"`)) ||
          js.body.match(new RegExp(`operationName:"${op}"[^}]{0,600}?queryId:"([A-Za-z0-9_-]{10,})"`));
        if (m) found[op] = m[1];
      }
    } catch (_) {}
  }
  console.log('found:', JSON.stringify(found));
  fs.writeFileSync(path.join(OUT, 'queryids.json'), JSON.stringify(found, null, 2));

  // 用 Viewer 校验会话
  if (found.Viewer) {
    for (const features of [
      { rweb_video_screen_enabled: false, responsive_web_graphql_timeline_navigation_enabled: true },
      {},
    ]) {
      const qs = new URLSearchParams({
        variables: '{}',
        features: JSON.stringify(features),
      });
      const r = await request('x.com', `/i/api/graphql/${found.Viewer}/Viewer?${qs}`, H);
      console.log(`\nViewer -> ${r.status}`);
      console.log(r.body.replace(/\s+/g, ' ').slice(0, 500));
      if (r.status === 200) { fs.writeFileSync(path.join(OUT, 'viewer.json'), r.body); break; }
    }
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
