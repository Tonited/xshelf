// 在已登录的 Chrome 里打开 likes 页，抓现行 GraphQL 请求（queryId + 真实响应）。
// 目的：验证 cookie 能拿到数据，并取得当前有效的 queryId。
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PORT = 9420;
const PROXY = process.env.X_PROXY || 'http://127.0.0.1:7897';
const SCREEN_NAME = process.env.X_SCREEN_NAME || '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map(); this.handlers = [];
    this.ready = new Promise((res, rej) => {
      ws.addEventListener('open', () => res());
      ws.addEventListener('error', () => rej(new Error('ws error')));
    });
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      } else if (m.method) {
        for (const h of this.handlers) h(m.method, m.params);
      }
    });
  }
  on(fn) { this.handlers.push(fn); }
  async send(method, params = {}, timeoutMs = 40000) {
    await this.ready;
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('timeout ' + method)); }
      }, timeoutMs);
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true });
    if (r.exceptionDetails) throw new Error('eval: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

(async () => {
  const userDir = path.join(OUT, 'profile-google');
  const args = [
    `--remote-debugging-port=${PORT}`, `--user-data-dir=${userDir}`, `--proxy-server=${PROXY}`,
    '--no-first-run', '--no-default-browser-check', '--disable-crash-reporter',
    '--disable-blink-features=AutomationControlled', '--window-size=1400,1000', 'about:blank',
  ];
  const out = fs.openSync(path.join(OUT, 'v-out.log'), 'w');
  const err = fs.openSync(path.join(OUT, 'v-err.log'), 'w');
  const proc = spawn(CHROME, args, { stdio: ['ignore', out, err] });

  let page = null;
  for (let i = 0; i < 60; i++) {
    await sleep(400);
    try {
      const list = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
      page = list.find((t) => t.type === 'page');
      if (page) break;
    } catch (_) {}
  }
  if (!page) throw new Error('no page');

  const cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await cdp.ready;
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Network.enable');

  const graphql = [];
  const responses = new Map();
  cdp.on((method, params) => {
    if (method === 'Network.requestWillBeSent') {
      const u = params.request.url;
      if (u.includes('/i/api/graphql/')) {
        const m = u.match(/\/i\/api\/graphql\/([^/]+)\/([^?]+)/);
        graphql.push({ url: u, qid: m && m[1], op: m && m[2], id: params.requestId });
      }
    }
    if (method === 'Network.responseReceived') {
      responses.set(params.requestId, params.response.status);
    }
  });

  const shots = async (name) => {
    try {
      const s = await cdp.send('Page.captureScreenshot', { format: 'png' });
      fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(s.data, 'base64'));
      console.log('shot saved:', name);
    } catch (_) {}
  };

  try {
    // 1) 先确认已登录
    await cdp.send('Page.navigate', { url: 'https://x.com/home' });
    await sleep(10000);
    const state = await cdp.eval(`(() => ({
      url: location.href,
      title: document.title,
      loggedIn: !!document.querySelector('[data-testid="AppTabBar_Home_Link"]'),
      bodyStart: (document.body?.innerText || '').slice(0, 300),
    }))()`);
    console.log('home state:', JSON.stringify(state, null, 2));
    await shots('v-home');

    // 2) 找到 sid，去 likes 页
    let sid = SCREEN_NAME;
    if (!sid) {
      const fromApp = await cdp.eval(`(() => {
        const a = document.querySelector('[data-testid="AppTabBar_Profile_Link"]');
        return a ? a.getAttribute('href') : null;
      })()`);
      console.log('profile link:', fromApp);
      if (fromApp) sid = fromApp.replace(/^\//, '');
    }
    console.log('screen name:', sid);

    if (sid) {
      await cdp.send('Page.navigate', { url: `https://x.com/${sid}/likes` });
      await sleep(12000);
      const likesState = await cdp.eval(`(() => ({
        url: location.href,
        text: (document.body?.innerText || '').slice(0, 400),
        cells: document.querySelectorAll('[data-testid="cellInnerDiv"]').length,
      }))()`);
      console.log('likes state:', JSON.stringify(likesState, null, 2));
      await shots('v-likes');
    }

    console.log('\n=== graphql requests seen ===');
    const uniq = [];
    const seen = new Set();
    for (const g of graphql) {
      const k = `${g.qid}/${g.op}`;
      if (seen.has(k)) continue;
      seen.add(k);
      uniq.push(g);
      console.log(`${g.op}  qid=${g.qid}  status=${responses.get(g.id) ?? '?'}`);
    }
    fs.writeFileSync(path.join(OUT, 'graphql-seen.json'), JSON.stringify(
      uniq.map((g) => ({ op: g.op, qid: g.qid, url: g.url })), null, 2));

    // 3) 直接把 Likes 的真实响应体捞出来看有没有数据
    for (const g of uniq.filter((x) => x.op === 'Likes').slice(0, 1)) {
      try {
        const body = await cdp.send('Network.getResponseBody', { requestId: g.id });
        fs.writeFileSync(path.join(OUT, 'likes-real.json'), body.body);
        const j = JSON.parse(body.body);
        const inst = j?.data?.user?.result?.timeline_v2?.timeline?.instructions
          || j?.data?.user?.result?.timeline?.timeline?.instructions || [];
        const add = inst.find((i) => i.type === 'TimelineAddEntries');
        const entries = add?.entries || [];
        const tweets = entries.filter((e) => (e.entryId || '').startsWith('tweet-'));
        console.log('\nLikes response: bytes=', body.body.length, '| entries=', entries.length, '| tweets=', tweets.length);
        for (const t of tweets.slice(0, 3)) {
          const r = t.content?.itemContent?.tweet_results?.result;
          const legacy = r?.legacy || r?.tweet?.legacy;
          const user = r?.core?.user_results?.result?.legacy?.screen_name;
          console.log(' -', (legacy?.full_text || '').replace(/\s+/g, ' ').slice(0, 60), '| @' + (user || '?'));
        }
        if (j.errors) console.log('errors:', JSON.stringify(j.errors).slice(0, 200));
      } catch (e) {
        console.log('getResponseBody failed:', e.message);
      }
    }
  } finally {
    cdp.close();
    try { proc.kill(); } catch (_) {}
    try { fs.closeSync(out); fs.closeSync(err); } catch (_) {}
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
