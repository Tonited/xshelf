#!/usr/bin/env node
/**
 * dist 局域网文件共享服务（零依赖，Node.js 内置模块实现）
 *
 * 用法:
 *   node _share-server.js [端口]        # 默认 8080
 *   PORT=8080 node _share-server.js
 *
 * 特性:
 *   - 绑定 0.0.0.0，局域网内其他设备可直接访问
 *   - 目录浏览 / 文件下载
 *   - 支持 HTTP Range（断点续传、大 APK 分段下载）
 *   - 中文文件名安全处理
 *   - 路径穿越防护
 */
'use strict';

const http = require('http');
const fs = require('fs');
const path = require('path');
const os = require('os');

const ROOT = __dirname;
const PORT = Number(process.env.PORT || process.argv[2] || 8080);
const HOST = '0.0.0.0';
const VERSION = '1.0.0';

// 内部文件：不在目录列表中展示，也不允许下载
const INTERNAL = new Set([
  '_share-server.js',
  '_share.log',
  '_share.err.log',
  '_share.pid',
  'start-share.ps1',
  'stop-share.ps1',
  'allow-lan-firewall.ps1',
  'README-SHARE.md',
]);

const MIME = {
  '.apk': 'application/vnd.android.package-archive',
  '.aab': 'application/octet-stream',
  '.ipa': 'application/octet-stream',
  '.apks': 'application/octet-stream',
  '.ico': 'image/x-icon',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.gif': 'image/gif',
  '.webp': 'image/webp',
  '.svg': 'image/svg+xml',
  '.bmp': 'image/bmp',
  '.txt': 'text/plain; charset=utf-8',
  '.log': 'text/plain; charset=utf-8',
  '.md': 'text/plain; charset=utf-8',
  '.html': 'text/html; charset=utf-8',
  '.htm': 'text/html; charset=utf-8',
  '.css': 'text/css; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.xml': 'application/xml; charset=utf-8',
  '.csv': 'text/csv; charset=utf-8',
  '.zip': 'application/zip',
  '.rar': 'application/vnd.rar',
  '.7z': 'application/x-7z-compressed',
  '.gz': 'application/gzip',
  '.tar': 'application/x-tar',
  '.pdf': 'application/pdf',
  '.doc': 'application/msword',
  '.docx': 'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
  '.xls': 'application/vnd.ms-excel',
  '.xlsx': 'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
  '.ppt': 'application/vnd.ms-powerpoint',
  '.pptx': 'application/vnd.openxmlformats-officedocument.presentationml.presentation',
  '.mp4': 'video/mp4',
  '.webm': 'video/webm',
  '.mp3': 'audio/mpeg',
  '.wav': 'audio/wav',
  '.exe': 'application/vnd.microsoft.portable-executable',
  '.msi': 'application/x-msi',
  '.dmg': 'application/x-apple-diskimage',
  '.iso': 'application/x-iso9660-image',
};

// 浏览器可直接预览（inline），其余类型强制下载（attachment）
const INLINE_EXT = new Set([
  '.txt', '.log', '.md', '.html', '.htm', '.css', '.js', '.json', '.xml', '.csv',
  '.png', '.jpg', '.jpeg', '.gif', '.webp', '.svg', '.bmp', '.ico',
  '.pdf', '.mp4', '.webm', '.mp3', '.wav',
]);

const pad = (n) => String(n).padStart(2, '0');

function log(...args) {
  console.log(`[${new Date().toLocaleString('zh-CN', { hour12: false })}]`, ...args);
}

function esc(s) {
  return String(s).replace(/[&<>"']/g, (c) => ({
    '&': '&amp;', '<': '&lt;', '>': '&gt;', '"': '&quot;', "'": '&#39;',
  }[c]));
}

function fmtSize(bytes) {
  if (!Number.isFinite(bytes)) return '—';
  if (bytes < 1024) return bytes + ' B';
  const units = ['KB', 'MB', 'GB', 'TB'];
  let v = bytes / 1024;
  let i = 0;
  while (v >= 1024 && i < units.length - 1) { v /= 1024; i++; }
  return `${v >= 100 ? v.toFixed(0) : v.toFixed(1)} ${units[i]}`;
}

function fmtTime(d) {
  return `${d.getFullYear()}-${pad(d.getMonth() + 1)}-${pad(d.getDate())} ${pad(d.getHours())}:${pad(d.getMinutes())}`;
}

function lanInterfaces() {
  const out = [];
  const ifs = os.networkInterfaces();
  for (const name of Object.keys(ifs)) {
    for (const it of ifs[name] || []) {
      if (it.family === 'IPv4' && !it.internal) out.push({ name, address: it.address });
    }
  }
  return out;
}

function sendError(res, code, message) {
  const body = `<!doctype html><meta charset="utf-8"><title>${code}</title>
<body style="font-family:system-ui,'Segoe UI',sans-serif;padding:40px;color:#333">
<h1 style="font-size:48px;margin:0;color:#c0392b">${code}</h1>
<p style="font-size:18px">${esc(message)}</p>
<p><a href="./" style="color:#2563eb">← 返回根目录</a></p>`;
  res.writeHead(code, {
    'Content-Type': 'text/html; charset=utf-8',
    'Content-Length': Buffer.byteLength(body),
    'Cache-Control': 'no-store',
  });
  res.end(body);
}

function renderIndex(reqUrl, absDir, entries) {
  const segs = reqUrl.split('/').filter(Boolean);
  const crumbs = [`<a href="/">🏠 根目录</a>`];
  let acc = '';
  segs.forEach((seg) => {
    acc += '/' + encodeURIComponent(seg);
    crumbs.push(`<a href="${acc}/">${esc(seg)}</a>`);
  });

  const rows = entries.map((e) => {
    const href = encodeURIComponent(e.name) + (e.isDir ? '/' : '');
    const icon = e.isDir ? '📁' : '📄';
    return `<tr>
      <td class="ic">${icon}</td>
      <td class="nm"><a href="${href}">${esc(e.name)}</a></td>
      <td class="sz">${e.isDir ? '—' : fmtSize(e.size)}</td>
      <td class="tm">${fmtTime(e.mtime)}</td>
    </tr>`;
  }).join('\n');

  const lan = lanInterfaces();
  const lanTxt = lan.map((i) => `<code>http://${i.address}:${PORT}/</code>`).join(' ') || '<code>（未检测到局域网地址）</code>';

  const body = `<!doctype html>
<html lang="zh-CN">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>共享目录 · ${esc(reqUrl)}</title>
<style>
  :root{color-scheme:light dark}
  *{box-sizing:border-box}
  body{margin:0;padding:28px;font-family:system-ui,-apple-system,'Segoe UI','Microsoft YaHei',sans-serif;
       background:#f6f7f9;color:#1f2328}
  @media (prefers-color-scheme:dark){body{background:#161b22;color:#e6edf3}}
  h1{font-size:20px;margin:0 0 6px}
  .sub{font-size:13px;opacity:.72;margin-bottom:18px}
  .crumb{font-size:14px;margin-bottom:14px}
  .crumb a{color:#2563eb;text-decoration:none}
  .crumb a:hover{text-decoration:underline}
  .card{background:#fff;border:1px solid #e3e6ea;border-radius:10px;overflow:hidden;
        box-shadow:0 1px 2px rgba(0,0,0,.04)}
  @media (prefers-color-scheme:dark){.card{background:#1c2128;border-color:#30363d}}
  table{width:100%;border-collapse:collapse;font-size:14px}
  th,td{padding:11px 14px;text-align:left;border-bottom:1px solid #eef0f2}
  @media (prefers-color-scheme:dark){th,td{border-color:#2b3138}}
  th{font-weight:600;font-size:12px;letter-spacing:.04em;text-transform:uppercase;opacity:.6;
     background:#fafbfc}
  @media (prefers-color-scheme:dark){th{background:#20262e}}
  tr:last-child td{border-bottom:none}
  tbody tr:hover{background:#f4f8ff}
  @media (prefers-color-scheme:dark){tbody tr:hover{background:#222a33}}
  td.ic{width:34px;text-align:center;font-size:16px}
  td.sz,td.tm{white-space:nowrap;font-variant-numeric:tabular-nums;opacity:.8}
  td.sz{width:110px;text-align:right}
  td.tm{width:150px}
  td.nm a{color:#2563eb;text-decoration:none;word-break:break-all}
  td.nm a:hover{text-decoration:underline}
  .empty{padding:28px;text-align:center;opacity:.6}
  footer{margin-top:18px;font-size:12px;opacity:.6;line-height:1.7}
  code{background:rgba(127,127,127,.14);padding:2px 6px;border-radius:5px;font-size:12px}
</style>
</head>
<body>
<h1>📦 文件共享</h1>
<div class="sub">目录：<code>${esc(absDir)}</code> · 端口 ${PORT} · 服务 v${VERSION}</div>
<div class="crumb">${crumbs.join(' / ')}</div>
<div class="card">
${entries.length ? `<table>
  <thead><tr><th class="ic"></th><th>名称</th><th style="text-align:right">大小</th><th>修改时间</th></tr></thead>
  <tbody>
${rows}
  </tbody>
</table>` : '<div class="empty">此目录为空</div>'}
</div>
<footer>
  局域网访问地址：${lanTxt}<br>
  共 ${entries.filter((e) => !e.isDir).length} 个文件 · 支持断点续传
</footer>
</body>
</html>`;
  return body;
}

function serveFile(req, res, absFile, st) {
  const ext = path.extname(absFile).toLowerCase();
  const baseName = path.basename(absFile);
  const inline = INLINE_EXT.has(ext);

  // RFC 5987：中文文件名下载时保持原样
  const asciiFallback = baseName.replace(/[^\x20-\x7e]/g, '_').replace(/["\\]/g, '_');
  const disposition = `${inline ? 'inline' : 'attachment'}; filename="${asciiFallback}"; filename*=UTF-8''${encodeURIComponent(baseName)}`;

  const headers = {
    'Content-Type': MIME[ext] || 'application/octet-stream',
    'Accept-Ranges': 'bytes',
    'Last-Modified': st.mtime.toUTCString(),
    'Content-Disposition': disposition,
    'Cache-Control': 'no-cache',
    'X-Content-Type-Options': 'nosniff',
  };

  let status = 200;
  let start = 0;
  let end = st.size - 1;

  const rangeHeader = req.headers.range;
  if (rangeHeader) {
    const m = /^bytes=(\d*)-(\d*)$/.exec(String(rangeHeader).trim());
    if (m) {
      const hasStart = m[1] !== '';
      const hasEnd = m[2] !== '';
      if (hasStart) {
        start = Number(m[1]);
        if (hasEnd) end = Number(m[2]);
      } else if (hasEnd) {
        // bytes=-500 → 最后 500 字节
        const suffix = Number(m[2]);
        start = Math.max(0, st.size - suffix);
      }
      if (!Number.isFinite(start) || !Number.isFinite(end) || start > end || start >= st.size) {
        res.writeHead(416, { 'Content-Range': `bytes */${st.size}` });
        return res.end();
      }
      if (end >= st.size) end = st.size - 1;
      status = 206;
      headers['Content-Range'] = `bytes ${start}-${end}/${st.size}`;
      headers['Content-Length'] = end - start + 1;
    }
  }

  if (status === 200) headers['Content-Length'] = st.size;

  res.writeHead(status, headers);
  if (req.method === 'HEAD' || st.size === 0) return res.end();

  const stream = fs.createReadStream(absFile, { start, end });
  stream.on('error', (err) => {
    log('读取文件失败:', absFile, err.message);
    res.destroy(err);
  });
  // 客户端中断（手机下载取消）时不当作异常
  res.on('close', () => stream.destroy());
  stream.pipe(res);
}

const server = http.createServer((req, res) => {
  const t0 = Date.now();
  const remote = (req.socket.remoteAddress || '').replace(/^::ffff:/, '');

  res.on('finish', () => {
    log(`${remote} ${req.method} ${req.url} → ${res.statusCode} ${Date.now() - t0}ms`);
  });

  if (req.method !== 'GET' && req.method !== 'HEAD') {
    res.writeHead(405, { Allow: 'GET, HEAD', 'Content-Type': 'text/plain; charset=utf-8' });
    return res.end('Method Not Allowed');
  }

  let pathname;
  try {
    pathname = decodeURIComponent(new URL(req.url, 'http://localhost').pathname);
  } catch {
    return sendError(res, 400, '请求地址编码错误');
  }

  // 防路径穿越
  const target = path.resolve(ROOT, '.' + path.posix.normalize('/' + pathname));
  if (target !== ROOT && !target.startsWith(ROOT + path.sep)) {
    return sendError(res, 403, '禁止访问该路径');
  }

  const relName = path.relative(ROOT, target).split(path.sep)[0];
  if (relName && INTERNAL.has(relName)) {
    return sendError(res, 404, '文件不存在');
  }

  fs.stat(target, (err, st) => {
    if (err) return sendError(res, 404, '文件或目录不存在');

    if (st.isDirectory()) {
      // 目录地址统一带尾斜杠，保证相对链接正确
      if (!pathname.endsWith('/')) {
        res.writeHead(301, { Location: encodeURI(pathname) + '/' });
        return res.end();
      }
      fs.readdir(target, { withFileTypes: true }, (err2, names) => {
        if (err2) return sendError(res, 500, '读取目录失败');
        const entries = [];
        for (const d of names) {
          if (d.name.startsWith('.')) continue;
          if (INTERNAL.has(d.name)) continue;
          const full = path.join(target, d.name);
          let s;
          try { s = fs.statSync(full); } catch { continue; }
          entries.push({
            name: d.name,
            isDir: s.isDirectory(),
            size: s.size,
            mtime: s.mtime,
          });
        }
        entries.sort((a, b) => {
          if (a.isDir !== b.isDir) return a.isDir ? -1 : 1;
          return a.name.localeCompare(b.name, 'zh-CN');
        });
        const html = renderIndex(pathname, target, entries);
        res.writeHead(200, {
          'Content-Type': 'text/html; charset=utf-8',
          'Content-Length': Buffer.byteLength(html),
          'Cache-Control': 'no-store',
        });
        res.end(req.method === 'HEAD' ? undefined : html);
      });
      return;
    }

    if (!st.isFile()) return sendError(res, 403, '不支持的文件类型');
    serveFile(req, res, target, st);
  });
});

server.on('error', (err) => {
  if (err.code === 'EADDRINUSE') {
    console.error(`\n端口 ${PORT} 已被占用。请换一个端口：node _share-server.js 8081\n`);
    process.exit(1);
  }
  console.error('服务异常:', err);
  process.exit(1);
});

server.listen(PORT, HOST, () => {
  const lan = lanInterfaces();
  console.log('='.repeat(56));
  console.log('  dist 局域网文件共享服务已启动');
  console.log('='.repeat(56));
  console.log(`  根目录  : ${ROOT}`);
  console.log(`  本机    : http://127.0.0.1:${PORT}/`);
  if (lan.length) {
    for (const i of lan) console.log(`  局域网  : http://${i.address}:${PORT}/   (${i.name})`);
  } else {
    console.log('  局域网  : 未检测到可用网卡');
  }
  console.log('='.repeat(56));
  console.log('  提示: 其他设备需与本机处于同一局域网，且防火墙放行该端口');
  console.log('');
});

// 优雅退出
for (const sig of ['SIGINT', 'SIGTERM']) {
  process.on(sig, () => {
    log(`收到 ${sig}，正在关闭服务…`);
    server.close(() => process.exit(0));
    setTimeout(() => process.exit(0), 2000).unref();
  });
}
