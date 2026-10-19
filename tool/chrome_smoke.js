// 最小化验证：能否用 CDP 端口启动系统 Chrome（输出落文件，避开沙箱的管道限制）。
const { spawn, execSync } = require('child_process');
const fs = require('fs');
const path = require('path');

const CHROME = 'C:\\Program Files\\Google\\Chrome\\Application\\chrome.exe';
const OUT = path.join(__dirname, '..', 'build', 'auth_probe');
fs.mkdirSync(OUT, { recursive: true });

const log = fs.openSync(path.join(OUT, 'chrome-stdout.log'), 'w');
const err = fs.openSync(path.join(OUT, 'chrome-stderr.log'), 'w');
const userDir = path.join(OUT, 'profile-test');
fs.rmSync(userDir, { recursive: true, force: true });

const args = [
  '--remote-debugging-port=9333',
  `--user-data-dir=${userDir}`,
  '--no-first-run',
  '--no-default-browser-check',
  '--headless=new',
  'about:blank',
];

console.log('spawning:', CHROME, args.join(' '));
const p = spawn(CHROME, args, { stdio: ['ignore', log, err] });
p.on('error', (e) => console.log('spawn error:', e.message));
p.on('exit', (c, s) => console.log('chrome exited:', c, s));

(async () => {
  for (let i = 0; i < 40; i++) {
    await new Promise((r) => setTimeout(r, 500));
    try {
      const r = await fetch('http://127.0.0.1:9333/json/version');
      if (r.ok) {
        const j = await r.json();
        console.log('OK debugger:', j.Browser, j.webSocketDebuggerUrl);
        break;
      }
    } catch (_) {}
    if (i === 39) console.log('debugger never came up');
  }
  try {
    const ps = execSync('tasklist /FI "IMAGENAME eq chrome.exe" /FO CSV').toString();
    console.log('tasklist lines:', ps.split('\n').length);
  } catch (e) { console.log('tasklist failed', e.message); }
  try { p.kill(); } catch (_) {}
  fs.closeSync(log); fs.closeSync(err);
  const e = fs.readFileSync(path.join(OUT, 'chrome-stderr.log'), 'utf8');
  console.log('--- stderr ---\n' + e.slice(0, 2000));
})();
