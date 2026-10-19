// X 登录流程实测工具（系统 Chrome + CDP）。
// 每次运行启动一个独立 Chrome（复用同一 profile 以保留 cookie），走完一段流程后退出。
// 用法: node tool/xlogin.js <mode>
//   dump    打开 X 登录页，截图 + dump DOM
//   login   填邮箱密码并提交，逐步 dump + 截图
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
const PORT = 9410;
const PROXY = process.env.X_PROXY || 'http://127.0.0.1:7897';
const MODE = process.argv[2] || 'dump';
const EMAIL = process.env.X_EMAIL || '';
const PASSWORD = process.env.X_PASSWORD || '';

const sleep = (ms) => new Promise((r) => setTimeout(r, ms));
fs.mkdirSync(OUT, { recursive: true });

// ---------------------------------------------------------------- CDP 客户端
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
  async send(method, params = {}, timeoutMs = 45000) {
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
      expression,
      returnByValue: true,
      awaitPromise: true,
    });
    if (r.exceptionDetails) {
      throw new Error(
        'eval threw: ' +
          (r.exceptionDetails.exception?.description || r.exceptionDetails.text),
      );
    }
    return r.result.value;
  }
  close() { try { this.ws.close(); } catch (_) {} }
}

// ---------------------------------------------------------------- 工具函数
async function launch() {
  const userDir = path.join(OUT, 'profile-x');
  fs.mkdirSync(userDir, { recursive: true });
  const args = [
    `--remote-debugging-port=${PORT}`,
    `--user-data-dir=${userDir}`,
    `--proxy-server=${PROXY}`,
    '--no-first-run',
    '--no-default-browser-check',
    '--disable-crash-reporter',
    '--disable-gpu',
    '--window-size=1280,1100',
    'about:blank',
  ];
  const out = fs.openSync(path.join(OUT, 'x-out.log'), 'w');
  const err = fs.openSync(path.join(OUT, 'x-err.log'), 'w');
  const proc = spawn(CHROME, args, { stdio: ['ignore', out, err] });
  for (let i = 0; i < 60; i++) {
    await sleep(400);
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/list`);
      if (r.ok) {
        const list = await r.json();
        const page = list.find((t) => t.type === 'page');
        if (page) {
          const ws = new WebSocket(page.webSocketDebuggerUrl);
          const cdp = new CDP(ws);
          await cdp.ready;
          cdp.send('Page.enable');
          cdp.send('Runtime.enable');
          cdp.send('Network.enable');
          return { proc, cdp, logFds: [out, err] };
        }
      }
    } catch (_) {}
  }
  throw new Error('CDP page never became available');
}

const SNAPSHOT = `(() => {
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const inputs = [...document.querySelectorAll('input,textarea')].filter(vis).map((el) => ({
    type: el.type, name: el.name, testid: el.getAttribute('data-testid'),
    autocomplete: el.autocomplete, placeholder: el.placeholder,
    ariaLabel: el.getAttribute('aria-label'), value: el.type === 'password' ? '***' : el.value,
  }));
  const clickable = [...document.querySelectorAll('[role="button"],button,a[href]')]
    .filter(vis)
    .map((el) => ({
      testid: el.getAttribute('data-testid'),
      text: (el.innerText || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim().slice(0, 50),
    }))
    .filter((b) => b.text || b.testid);
  return {
    url: location.href,
    title: document.title,
    text: (document.body?.innerText || '').slice(0, 1500),
    inputs, clickable: clickable.slice(0, 40),
  };
})()`;

async function snap(cdp, name) {
  const s = await cdp.eval(SNAPSHOT);
  fs.writeFileSync(path.join(OUT, `${name}.json`), JSON.stringify(s, null, 2));
  try {
    const shot = await cdp.send('Page.captureScreenshot', { format: 'png' });
    fs.writeFileSync(path.join(OUT, `${name}.png`), Buffer.from(shot.data, 'base64'));
  } catch (e) {
    console.log('screenshot failed:', e.message);
  }
  console.log(`\n===== ${name} =====`);
  console.log('url:', s.url);
  console.log('title:', s.title);
  console.log('inputs:', JSON.stringify(s.inputs));
  console.log('clickable:', JSON.stringify(s.clickable.slice(0, 20)));
  console.log('text:', s.text.replace(/\n+/g, ' | ').slice(0, 600));
  return s;
}

// React 受控输入必须走 native setter + input 事件，否则 state 不变。
// 新版登录页（/i/jf/onboarding/web）用 name="username_or_email" / "password"，
// 没有 data-testid，所以这里按 name 或 testid 都能命中。
const fillInput = (selector, value) => `(() => {
  const el = document.querySelector(${JSON.stringify(selector)});
  if (!el) return 'NOT_FOUND';
  el.focus();
  const setter = Object.getOwnPropertyDescriptor(window.HTMLInputElement.prototype, 'value').set;
  setter.call(el, ${JSON.stringify(value)});
  el.dispatchEvent(new Event('input', { bubbles: true }));
  el.dispatchEvent(new Event('change', { bubbles: true }));
  el.dispatchEvent(new KeyboardEvent('keyup', { bubbles: true }));
  return 'FILLED:' + el.value.length;
})()`;

// 按可见文本点按钮（新版登录页按钮没有 testid）。
const clickByText = (labels) => `(() => {
  const want = ${JSON.stringify(labels)};
  const vis = (el) => {
    const r = el.getBoundingClientRect();
    const s = getComputedStyle(el);
    return r.width > 1 && r.height > 1 && s.visibility !== 'hidden' && s.display !== 'none';
  };
  const els = [...document.querySelectorAll('[role="button"],button,input[type="submit"]')].filter(vis);
  for (const el of els) {
    const txt = (el.innerText || el.value || el.getAttribute('aria-label') || '').replace(/\\s+/g, ' ').trim();
    for (const w of want) {
      if (txt === w || txt.includes(w)) {
        el.click();
        return 'CLICKED:' + txt;
      }
    }
  }
  return 'NOT_FOUND';
})()`;

const clickTestid = (testid) => `(() => {
  const el = document.querySelector('[data-testid="${testid}"]');
  if (!el) return 'NOT_FOUND';
  el.click();
  return 'CLICKED';
})()`;

async function cookies(cdp) {
  const { cookies: list } = await cdp.send('Network.getAllCookies');
  const pick = list.filter((c) => ['.x.com', 'x.com'].some((d) => c.domain === d || c.domain === '.' + d));
  const map = {};
  for (const c of pick) map[c.name] = c.value;
  return map;
}

(async () => {
  const { proc, cdp, logFds } = await launch();
  try {
    if (MODE === 'dump') {
      await cdp.send('Page.navigate', { url: 'https://x.com/i/flow/login' });
      await sleep(9000);
      let s = await snap(cdp, 'dump-1');
      if (s.text.length < 40) {
        await sleep(8000);
        s = await snap(cdp, 'dump-2');
      }
      const c = await cookies(cdp);
      console.log('cookies:', Object.keys(c).join(','));
    }

    if (MODE === 'login') {
      await cdp.send('Page.navigate', { url: 'https://x.com/i/flow/login' });
      await sleep(9000);

      let filledUser = false;
      let filledPass = false;
      for (let round = 1; round <= 10; round++) {
        const s = await snap(cdp, `login-r${round}`);
        const hasUser = s.inputs.some((i) => i.name === 'username_or_email');
        const hasPass = s.inputs.some((i) => i.name === 'password');
        const url = s.url;

        if (url.includes('/home')) {
          console.log('\n>>> REACHED /home');
          break;
        }

        // 出现验证码 / 二次确认：不再自动往下猜，交给调用者看截图和文本
        const challenge = /验证|verify|confirmation|安全|unusual|可疑|输入发送到|code/i.test(s.text) &&
          !hasPass;

        if (hasUser && !filledUser) {
          console.log('\n>> fill username');
          console.log(await cdp.eval(fillInput('input[name="username_or_email"]', EMAIL)));
          filledUser = true;
          await sleep(600);
          console.log('>> click 继续');
          console.log(await cdp.eval(clickByText(['继续', 'Next', '下一步', 'Log in', '登录'])));
          await sleep(6000);
          continue;
        }

        if (hasPass && !filledPass) {
          console.log('\n>> fill password');
          console.log(await cdp.eval(fillInput('input[name="password"]', PASSWORD)));
          filledPass = true;
          await sleep(600);
          console.log('>> click 继续');
          console.log(await cdp.eval(clickByText(['继续', 'Next', '下一步', 'Log in', '登录'])));
          await sleep(8000);
          continue;
        }

        if (challenge) {
          console.log('\n>>> CHALLENGE DETECTED, stopping for human input');
          break;
        }

        await sleep(4000);
      }

      const c = await cookies(cdp);
      console.log('\ncookies:', Object.keys(c).join(','));
      console.log('has auth_token:', Boolean(c.auth_token), 'has ct0:', Boolean(c.ct0));
      fs.writeFileSync(path.join(OUT, 'cookies.json'), JSON.stringify(c, null, 2));
      if (c.auth_token) console.log('auth_token len:', c.auth_token.length);
    }
  } finally {
    cdp.close();
    try { proc.kill(); } catch (_) {}
    for (const fd of logFds) { try { fs.closeSync(fd); } catch (_) {} }
  }
})().catch((e) => {
  console.error('FATAL', e.message);
  process.exit(1);
});
