// 在浏览器上下文里搜索已加载的 client-web JS，提取 GraphQL queryId。
// 裸 HTTP 抓首页会被 Cloudflare 403，浏览器里则不受影响。
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PORT = 9430;
const PROXY = process.env.X_PROXY || 'http://127.0.0.1:7897';
const OPS = ['Likes', 'UnfavoriteTweet', 'Viewer', 'UserByScreenName', 'FavoriteTweet'];
const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

class CDP {
  constructor(ws) {
    this.ws = ws; this.id = 0; this.pending = new Map();
    this.ready = new Promise((res, rej) => {
      ws.addEventListener('open', () => res());
      ws.addEventListener('error', () => rej(new Error('ws err')));
    });
    ws.addEventListener('message', (ev) => {
      const m = JSON.parse(ev.data);
      if (m.id && this.pending.has(m.id)) {
        const { resolve, reject } = this.pending.get(m.id);
        this.pending.delete(m.id);
        m.error ? reject(new Error(JSON.stringify(m.error))) : resolve(m.result);
      }
    });
  }
  async send(method, params = {}, t = 90000) {
    await this.ready;
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => { if (this.pending.has(id)) { this.pending.delete(id); reject(new Error('timeout ' + method)); } }, t);
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', { expression, returnByValue: true, awaitPromise: true }, 120000);
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
  const out = fs.openSync(path.join(OUT, 'q-out.log'), 'w');
  const err = fs.openSync(path.join(OUT, 'q-err.log'), 'w');
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
  const cdp = new CDP(new WebSocket(page.webSocketDebuggerUrl));
  await cdp.ready;
  await cdp.send('Page.enable'); await cdp.send('Runtime.enable');

  try {
    await cdp.send('Page.navigate', { url: 'https://x.com/home' });
    await sleep(12000);

    const result = await cdp.eval(`(async () => {
      const ops = ${JSON.stringify(OPS)};
      const found = {};
      // 1) 页面已加载的 script 标签
      let srcs = [...document.querySelectorAll('script[src]')].map(s => s.src)
        .filter(s => /client-web.*\\.js/.test(s));
      // 2) performance entries 里可能还有更多分包
      try {
        const perf = performance.getEntriesByType('resource')
          .map(e => e.name).filter(n => /client-web.*\\.js/.test(n));
        srcs = [...new Set([...srcs, ...perf])];
      } catch (e) {}
      const tried = [];
      for (const url of srcs) {
        let txt = '';
        try {
          const r = await fetch(url);
          if (!r.ok) { tried.push(url + ' -> ' + r.status); continue; }
          txt = await r.text();
        } catch (e) { tried.push(url + ' -> ERR'); continue; }
        for (const op of ops) {
          if (found[op]) continue;
          const a = txt.match(new RegExp('queryId:"([A-Za-z0-9_-]{10,})"[^}]{0,600}?operationName:"' + op + '"'));
          const b = txt.match(new RegExp('operationName:"' + op + '"[^}]{0,600}?queryId:"([A-Za-z0-9_-]{10,})"'));
          if (a) found[op] = { qid: a[1], src: url.split('/').pop() };
          else if (b) found[op] = { qid: b[1], src: url.split('/').pop() };
        }
      }
      return { scripts: srcs.length, found, tried: tried.slice(0, 10) };
    })()`);

    console.log('scripts scanned:', result.scripts);
    console.log('found:', JSON.stringify(result.found, null, 2));
    if (result.tried.length) console.log('unavailable:', result.tried.join('\n'));
    fs.writeFileSync(path.join(OUT, 'queryids.json'), JSON.stringify(result.found, null, 2));
  } finally {
    cdp.close();
    try { proc.kill(); } catch (_) {}
    try { fs.closeSync(out); fs.closeSync(err); } catch (_) {}
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
