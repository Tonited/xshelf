// 把 dist/ 临时共享到局域网，方便手机扫码/输网址下载 APK。
//
// 用法： node tool/serve-dist.js [目录=dist] [端口=8099]
//       手机浏览器打开 http://<这台电脑的局域网 IP>:8099/
//
// 只用 Node 内置模块（无依赖）。只读、只列目录、不写盘。

const http = require('node:http');
const fs = require('node:fs');
const fsp = require('node:fs/promises');
const path = require('node:path');
const os = require('node:os');

const root = path.resolve(process.argv[2] || 'dist');
const port = Number(process.argv[3] || 8099);

const MIME = {
  '.apk': 'application/vnd.android.package-archive',
  '.zip': 'application/zip',
  '.exe': 'application/octet-stream',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.json': 'application/json',
};

function escapeHtml(s) {
  return s.replace(/[&<>"]/g, (c) => ({ '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;' }[c]));
}

function human(bytes) {
  if (bytes > 1024 * 1024) return `${(bytes / 1024 / 1024).toFixed(1)} MB`;
  if (bytes > 1024) return `${(bytes / 1024).toFixed(0)} KB`;
  return `${bytes} B`;
}

async function index(res) {
  const entries = await fsp.readdir(root, { withFileTypes: true });
  const rows = [];
  for (const e of entries) {
    if (!e.isFile() || e.name.startsWith('_')) continue;
    const stat = await fsp.stat(path.join(root, e.name));
    rows.push(
      `<li><a href="/${encodeURIComponent(e.name)}">${escapeHtml(e.name)}</a> <small>${human(stat.size)}</small></li>`,
    );
  }
  const html = `<!doctype html><meta name=viewport content="width=device-width,initial-scale=1">
<title>xlikemanage 下载</title>
<style>body{font:16px/1.6 system-ui,sans-serif;margin:24px;max-width:640px}
li{margin:12px 0}small{color:#888}</style>
<h2>xlikemanage 安装包</h2><ul>${rows.join('')}</ul>
<p><small>直接点文件名下载；Android 会提示"未知来源"，允许即可。</small></p>`;
  res.writeHead(200, { 'content-type': 'text/html; charset=utf-8' });
  res.end(html);
}

const server = http.createServer(async (req, res) => {
  try {
    if (req.method !== 'GET' && req.method !== 'HEAD') {
      res.writeHead(405).end();
      return;
    }
    const url = new URL(req.url, 'http://localhost');
    const name = decodeURIComponent(url.pathname.replace(/^\//, ''));
    if (!name) return index(res);

    // 只允许 root 下的普通文件，挡掉 ../ 穿越。
    const target = path.join(root, path.basename(name));
    if (!target.startsWith(root + path.sep)) {
      res.writeHead(403).end();
      return;
    }
    const stat = await fsp.stat(target).catch(() => null);
    if (!stat || !stat.isFile()) {
      res.writeHead(404).end('not found');
      return;
    }

    const type = MIME[path.extname(target).toLowerCase()] || 'application/octet-stream';
    const range = req.headers.range;
    const base = {
      'content-type': type,
      'content-disposition': `attachment; filename="${path.basename(target)}"`,
      'accept-ranges': 'bytes',
    };

    if (range && /^bytes=\d*-\d*$/.test(range)) {
      const [startRaw, endRaw] = range.replace('bytes=', '').split('-');
      const start = startRaw ? Number(startRaw) : 0;
      const end = endRaw ? Math.min(Number(endRaw), stat.size - 1) : stat.size - 1;
      if (start > end || start >= stat.size) {
        res.writeHead(416, { 'content-range': `bytes */${stat.size}` }).end();
        return;
      }
      res.writeHead(206, {
        ...base,
        'content-range': `bytes ${start}-${end}/${stat.size}`,
        'content-length': end - start + 1,
      });
      if (req.method === 'HEAD') return res.end();
      fs.createReadStream(target, { start, end }).pipe(res);
      return;
    }

    res.writeHead(200, { ...base, 'content-length': stat.size });
    if (req.method === 'HEAD') return res.end();
    fs.createReadStream(target).pipe(res);
  } catch (e) {
    res.writeHead(500).end(String(e));
  }
});

server.listen(port, '0.0.0.0', () => {
  const nets = Object.values(os.networkInterfaces())
    .flat()
    .filter((n) => n && n.family === 'IPv4' && !n.internal)
    .map((n) => n.address);
  console.log(`serving ${root}`);
  console.log(`local:  http://127.0.0.1:${port}/`);
  for (const ip of nets) console.log(`phone:  http://${ip}:${port}/`);
});
