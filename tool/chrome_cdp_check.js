// 在沙箱外启动一个独立 Chrome 实例，验证 CDP 端口可用。
// 关键点：user-data-dir 路径含空格，必须用 spawn 的参数数组（而非命令行拼接）。
const { spawn } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
fs.mkdirSync(OUT, { recursive: true });

const PORT = Number(process.env.CDP_PORT || 9400);
const userDir = path.join(OUT, 'profile-cdp');
fs.rmSync(userDir, { recursive: true, force: true });

const args = [
  `--remote-debugging-port=${PORT}`,
  `--user-data-dir=${userDir}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--disable-crash-reporter',
  '--disable-gpu',
  '--window-size=1280,1000',
  'about:blank',
];

const out = fs.openSync(path.join(OUT, 'cdp-out.log'), 'w');
const err = fs.openSync(path.join(OUT, 'cdp-err.log'), 'w');
console.log('launching with user-data-dir:', userDir);
const p = spawn(CHROME, args, { stdio: ['ignore', out, err] });
p.on('error', (e) => console.log('spawn error:', e.message));
p.on('exit', (c) => console.log('chrome exited:', c));

(async () => {
  let ok = false;
  for (let i = 0; i < 60; i++) {
    await new Promise((r) => setTimeout(r, 500));
    try {
      const r = await fetch(`http://127.0.0.1:${PORT}/json/version`);
      if (r.ok) {
        const j = await r.json();
        console.log('DEBUGGER OK:', j.Browser);
        console.log('ws:', j.webSocketDebuggerUrl);
        ok = true;
        break;
      }
    } catch (_) {}
  }
  console.log(ok ? 'RESULT: PASS' : 'RESULT: FAIL');
  if (!ok) {
    console.log('--- stderr ---');
    console.log(fs.readFileSync(path.join(OUT, 'cdp-err.log'), 'utf8').slice(0, 1500));
    console.log('--- stdout ---');
    console.log(fs.readFileSync(path.join(OUT, 'cdp-out.log'), 'utf8').slice(0, 1500));
  }
  // 保留进程给后续脚本用；这里只验证端口，所以关掉。
  try { p.kill(); } catch (_) {}
  fs.closeSync(out); fs.closeSync(err);
})();
