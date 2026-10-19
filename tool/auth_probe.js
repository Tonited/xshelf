// 用系统 Chrome + CDP 真实打开 X 登录页，dump 页面结构。
// 目的：确认当前 X 登录页的真实流程（输入框/testid/是否有验证），而不是猜。
// 用法: node tool/auth_probe.js [dump|login]
const { spawn } = require('child_process');
const fs = require('fs');
const os = require('os');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const PORT = 9222;
const PROXY = process.env.X_PROXY || 'http://127.0.0.1:7897';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const MODE = process.argv[2] || 'dump';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));

function chromeLaunch() {
  const userDir = path.join(OUT, 'profile');
  fs.rmSync(userDir, { recursive: true, force: true });
  fs.mkdirSync(userDir, { recursive: true });
  const args = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${userDir}`,
    `--proxy-server=${PROXY}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-features=Translate,MediaRouter',
    '--window-size=1280,1000',
    '--window-position=0,0',
    'about:blank',
  ];
  const p = spawn(CHROME, args, { stdio: 'ignore', detached: false });
  return p;
}

async function waitForDebugger() {
  for (let i = 0; i < 100; i++) {
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
      if (r.ok) return await r.json();
    } catch (_) {}
    await sleep(200);
  }
  throw new Error('debugger port never came up');
}

class CDP {
  constructor(wsUrl) {
    this.ws = new WebSocket(wsUrl);
    this.id = 0;
    this.pending = new Map();
    this.events = [];
    this.ready = new Promise((res, rej) => {
      this.ws.addEventListener('open', () => res());
      this.ws.addEventListener('error', (e) => rej(new Error('ws error')));
    });
    this.ws.addEventListener('message', (ev) => {
      const msg = JSON.parse(ev.data);
      if (msg.id && this.pending.has(msg.id)) {
        const { resolve, reject } = this.pending.get(msg.id);
        this.pending.delete(msg.id);
        msg.error ? reject(new Error(JSON.stringify(msg.error))) : resolve(msg.result);
      } else if (msg.method) {
        this.events.push(msg);
      }
    });
  }
  async send(method, params = {}) {
    await this.ready;
    const id = ++this.id;
    return new Promise((resolve, reject) => {
      this.pending.set(id, { resolve, reject });
      this.ws.send(JSON.stringify({ id, method, params }));
      setTimeout(() => {
        if (this.pending.has(id)) {
          this.pending.delete(id);
          reject(new Error(`timeout ${method}`));
        }
      }, 45000);
    });
  }
  async eval(expr, awaitPromise = true) {
    const r = await this.send('Runtime.evaluate', {
      expression: expr,
      returnByValue: true,
      awaitPromise,
    });
    if (r.exceptionDetails) {
      throw new Error(
        'eval threw: ' +
          (r.exceptionDetails.exception?.description || r.exceptionDetails.text),
      );
    }
    return r.result.value;
  }
  close() {
    try { this.ws.close(); } catch (_) {}
  }
}

async function newPage(browserWs) {
  const targets = await (await fetch(`http://127.0.0.1:${PORT}/json/list`)).json();
  const blank = targets.find((t) => t.type === 'page');
  if (!blank) throw new Error('no page target');
  return new CDP(blank.webSocketDebuggerUrl);
}

const SNAPSHOT = `(() => {
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const inputs = [...document.querySelectorAll('input,textarea,select')]
    .filter(vis)
    .map((el) => ({
      tag: el.tagName.toLowerCase(),
      type: el.type,
      name: el.name,
      testid: el.getAttribute('data-testid'),
      autocomplete: el.autocomplete,
      placeholder: el.placeholder,
      ariaLabel: el.getAttribute('aria-label'),
    }));
  const buttons = [...document.querySelectorAll('[role="button"],button,a[href]')]
    .filter(vis)
    .map((el) => ({
      tag: el.tagName.toLowerCase(),
      testid: el.getAttribute('data-testid'),
      text: (el.innerText || el.getAttribute('aria-label') || '').trim().slice(0, 60),
      href: el.getAttribute('href'),
    }))
    .filter((b) => b.text || b.testid)
    .slice(0, 40);
  return {
    url: location.href,
    title: document.title,
    bodyLen: document.body ? document.body.innerText.length : 0,
    text: document.body ? document.body.innerText.slice(0, 1200) : '',
    inputs,
    buttons,
  };
})()`;

(async () => {
  fs.mkdirSync(OUT, { recursive: true });
  console.log('launching chrome...');
  const proc = chromeLaunch();
  const ver = await waitForDebugger();
  console.log('browser:', ver.Browser);

  const cdp = await newPage();
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Network.enable');

  await cdp.send('Page.navigate', { url: 'https://x.com/i/flow/login' });
  await sleep(6000);

  let snap = await cdp.eval(SNAPSHOT);
  // 等一会儿再看一次，X 的登录页是渐进渲染的
  if (snap.bodyLen < 50) {
    await sleep(6000);
    snap = await cdp.eval(SNAPSHOT);
  }

  const report = { step: 'initial', browser: ver.Browser, snapshot: snap };
  fs.writeFileSync(path.join(OUT, 'snapshot-1.json'), JSON.stringify(report, null, 2));
  console.log(JSON.stringify(report, null, 2));

  if (MODE === 'dump') {
    cdp.close();
    try { proc.kill(); } catch (_) {}
    return;
  }
})().catch((e) => {
  console.error('FATAL', e);
  process.exit(1);
});
