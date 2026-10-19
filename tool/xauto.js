// X 登录自动化（系统 Chrome + CDP）：Google 登录路径。
// 用法: node tool/xauto.js <mode>
//   google-dump   点「通过 Google 继续操作」，dump 弹出的 Google 页面
//   google-login  完整走一遍 Google 登录（邮箱 + 密码），逐步 dump
// 说明：Chrome 由 CDP 驱动时 navigator.webdriver 为 true，Google 会拒绝，
// 所以每个新 target 在加载前注入脚本把它抹掉。
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PORT = Number(process.env.CDP_PORT || 9411);
const PROXY = process.env.X_PROXY || 'http://127.0.0.1:7897';
const MODE = process.argv[2] || 'google-dump';
const EMAIL = process.env.X_EMAIL || '';
const PASSWORD = process.env.X_PASSWORD || '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

class CDP {
  constructor(ws) {
    this.ws = ws;
    this.id = 0;
    this.pending = new Map();
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
      }
    });
  }
  async send(method, params = {}, timeoutMs = 40000) {
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
      }, timeoutMs);
    });
  }
  async eval(expression) {
    const r = await this.send('Runtime.evaluate', {
      expression, returnByValue: true, awaitPromise: true,
    });
    if (r.exceptionDetails) {
      throw new Error('eval threw: ' + (r.exceptionDetails.exception?.description || r.exceptionDetails.text));
    }
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

async function listPages() {
  const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
  return await r.json();
}

async function attach(wsUrl) {
  const cdp = new CDP(new WebSocket(wsUrl));
  await cdp.ready;
  await cdp.send('Page.enable');
  await cdp.send('Runtime.enable');
  await cdp.send('Network.enable');
  return cdp;
}

async function xCookies(cdp) {
  const { cookies } = await cdp.send('Network.getAllCookies');
  const map = {};
  for (const c of cookies) {
    if (/(^|\.)x\.com$/.test(c.domain)) map[c.name] = c.value;
  }
  return map;
}

// 抹掉自动化指纹：Google 会据此判定「浏览器或应用可能不安全」。
const STEALTH = `(() => {
  try {
    Object.defineProperty(navigator, 'webdriver', { get: () => undefined });
    if (!window.chrome) window.chrome = {};
    window.chrome.runtime = window.chrome.runtime || {};
    Object.defineProperty(navigator, 'languages', { get: () => ['zh-CN','zh','en'] });
    Object.defineProperty(navigator, 'plugins', { get: () => [1,2,3,4,5] });
  } catch (e) {}
})()`;

async function stealth(cdp) {
  try {
    await cdp.send('Page.addScriptToEvaluateOnNewDocument', { source: STEALTH });
    await cdp.eval(STEALTH);
  } catch (_) {}
}

const SNAPSHOT = `(() => {
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const inputs = [...document.querySelectorAll('input,textarea')].filter(vis).map((el) => ({
    type: el.type, id: el.id, name: el.name, testid: el.getAttribute('data-testid'),
    placeholder: el.placeholder, ariaLabel: el.getAttribute('aria-label'),
    autocomplete: el.autocomplete,
    value: el.type === 'password' ? '***' : el.value,
  }));
  const clickable = [...document.querySelectorAll('[role="button"],button,a[href],input[type="submit"]')]
    .filter(vis)
    .map((el) => ({
      testid: el.getAttribute('data-testid'), id: el.id,
      text: (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 50),
    }))
    .filter((b) => b.text || b.testid || b.id);
  return {
    url: location.href,
    title: document.title,
    text: (document.body?.innerText || '').slice(0, 2000),
    inputs, clickable: clickable.slice(0, 40),
  };
})()`;

async function snap(cdp, name) {
  const s = await cdp.eval(SNAPSHOT);
  fs.writeFileSync(path.join(OUT, `${name}.json`), JSON.stringify(s, null, 2));
  try {
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png', captureBeyondViewport: false });
    fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(shot.data, 'base64'));
  } catch (_) {}
  console.log(`\n===== ${name} =====`);
  console.log('url:', s.url);
  console.log('title:', s.title);
  console.log('inputs:', JSON.stringify(s.inputs));
  console.log('clickable:', JSON.stringify(s.clickable.slice(0, 25)));
  console.log('text:', s.text.replace(/\n+/g, ' | ').slice(0, 800));
  return s;
}

const setVal = (selector, value) => `(() => {
  const el = document.querySelector(${JSON.stringify(selector)});
  if (!el) return 'NOT_FOUND';
  el.focus();
  const proto = el instanceof HTMLTextAreaElement ? HTMLTextAreaElement : HTMLInputElement;
  const setter = Object.getOwnPropertyDescriptor(proto.prototype, 'value').set;
  setter.call(el, ${JSON.stringify(value)});
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  return 'FILLED:' + el.value.length;
})()`;

// el.click() 不产生用户激活，window.open 会被 popup blocker 吃掉。
// 必须用 CDP 派发真实鼠标事件（浏览器才会认为这是用户手势）。
const findBox = (labels) => `(() => {
  const want = ${JSON.stringify(labels)};
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const els = [...document.querySelectorAll('[role="button"],button,a,input[type="submit"]')].filter(vis);
  for (const el of els) {
    const txt = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
    for (const w of want) {
      if (txt === w || txt.includes(w)) {
        el.scrollIntoView({ block: 'center' });
        const r = el.getBoundingClientRect();
        return { x: r.x + r.width / 2, y: r.y + r.height / 2, label: txt };
      }
    }
  }
  return null;
})()`;

async function realClick(cdp, labels) {
  const box = await cdp.eval(findBox(labels));
  if (!box) return 'NOT_FOUND';
  const { x, y } = box;
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseMoved', x, y });
  await cdp.send('Input.dispatchMouseEvent', { type: 'mousePressed', x, y, button: 'left', buttons: 1, clickCount: 1 });
  await sleep(80);
  await cdp.send('Input.dispatchMouseEvent', { type: 'mouseReleased', x, y, button: 'left', buttons: 0, clickCount: 1 });
  return 'CLICKED:' + box.label;
}

async function launch() {
  const userDir = path.join(OUT, 'profile-google');
  fs.mkdirSync(userDir, { recursive: true });
  const args = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${userDir}`,
    `--proxy-server=${PROXY}`,
    '--no-first-run', '--no-default-browser-check',
    '--disable-crash-reporter',
    '--disable-blink-features=AutomationControlled',
    '--disable-popup-blocking',
    '--window-size=1280,1000',
    'about:blank',
  ];
  const out = fs.openSync(path.join(OUT, 'g-out.log'), 'w');
  const err = fs.openSync(path.join(OUT, 'g-err.log'), 'w');
  const proc = spawn(CHROME, args, { stdio: ['ignore', out, err] });
  for (let i = 0; i < 60; i++) {
    await sleep(400);
    try {
      const list = await listPages();
      const page = list.find((t) => t.type === 'page');
      if (page) return { proc, page, fds: [out, err] };
    } catch (_) {}
  }
  throw new Error('CDP never came up');
}

(async () => {
  const { proc, page, fds } = await launch();
  const main = await attach(page.webSocketDebuggerUrl);
  try {
    await main.send('Page.navigate', { url: 'https://x.com/i/flow/login' });
    await sleep(8000);
    await stealth(main);
    await snap(main, 'g1-login');

    console.log('\n>> click Google 继续');
    console.log(await realClick(main, ['通过 Google 继续操作', 'Continue with Google']));
    await sleep(6000);

    // Google 可能开新 target，也可能当前页直接跳
    let targets = await listPages();
    let gp = targets.find((t) => t.type === 'page' && /google\.com/.test(t.url));
    if (!gp) {
      await sleep(5000);
      targets = await listPages();
      gp = targets.find((t) => t.type === 'page' && /google\.com/.test(t.url));
    }
    console.log('targets:', targets.filter(t => t.type === 'page').map(t => t.url));

    if (MODE === 'google-dump') {
      if (gp) {
        const g = await attach(gp.webSocketDebuggerUrl);
        await stealth(g);
        await sleep(1500);
        await snap(g, 'g2-google');
        g.close();
      } else {
        await snap(main, 'g2-main');
      }
      return;
    }

    // google-login：在 Google target 上填邮箱 + 密码
    if (!gp) {
      console.log('NO GOOGLE TARGET, dumping main instead');
      await snap(main, 'g2-main');
      return;
    }
    const g = await attach(gp.webSocketDebuggerUrl);
    await stealth(g);
    let emailDone = false;
    let passDone = false;
    let consentClicked = false;
    try {
    for (let round = 1; round <= 24; round++) {
      const s = await snap(g, `g-login-r${round}`);
      const u = s.url;

      if (/^https?:\/\/(www\.)?x\.com\//.test(u)) {
        console.log('>>> back on x.com');
        break;
      }

      // 1) 账号输入页
      if (/signin\/identifier/.test(u) && !passDone) {
        if (!emailDone) {
          console.log('\n>> fill google email');
          console.log(await g.eval(setVal('input[name="identifier"], input#identifierId', EMAIL)));
          await sleep(700);
          console.log('>> next');
          console.log(await realClick(g, ['下一步', 'Next']));
          emailDone = true;
          await sleep(5000);
          continue;
        }
      }

      // 2) 密码页
      const hasPass = s.inputs.some((i) => i.type === 'password');
      if (hasPass && /challenge\/pwd/.test(u)) {
        console.log('\n>> fill google password');
        console.log(await g.eval(setVal('input[name="Passwd"], input[type="password"]', PASSWORD)));
        await sleep(700);
        console.log('>> next');
        console.log(await realClick(g, ['下一步', 'Next']));
        passDone = true;
        await sleep(7000);
        continue;
      }

      // 3) OAuth 授权页：加载完后点「继续」
      if (/oauth\/v3\/consent/.test(u)) {
        const r = await realClick(g, ['继续', 'Continue', '允许', 'Allow']);
        if (r !== 'NOT_FOUND') {
          console.log('\n>> consent:', r);
          consentClicked = true;
          await sleep(7000);
          continue;
        }
        if (!/Loading|One moment/.test(s.text)) {
          console.log('\n>>> consent page loaded but no continue button found');
        }
        await sleep(3000);
        continue;
      }

      console.log('\n>>> unknown page:', u.slice(0, 120));
      await sleep(3000);
    }
    } catch (e) {
      // Google 弹窗在登录成功后会自动关闭，CDP 连接随之断开——这不是失败。
      console.log('\n>> google window ended:', e.message);
    } finally {
      try { g.close(); } catch (_) {}
    }

    // 回到 x.com：等主页面建立会话，然后把 cookie 捞出来
    console.log('\n>> waiting for x.com session...');
    await sleep(8000);
    await snap(main, 'g-final-main');
    const ck = await xCookies(main);
    fs.writeFileSync(path.join(OUT, 'cookies.json'), JSON.stringify(ck, null, 2));
    console.log('x.com cookies:', Object.keys(ck).join(','));
    console.log('auth_token:', Boolean(ck.auth_token), 'ct0:', Boolean(ck.ct0), 'twid:', Boolean(ck.twid));
  } finally {
    main.close();
    try { proc.kill(); } catch (_) {}
    for (const fd of fds) { try { fs.closeSync(fd); } catch (_) {} }
  }
})().catch((e) => { console.error('FATAL', e.message); process.exit(1); });
