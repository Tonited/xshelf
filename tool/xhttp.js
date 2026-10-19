// 走本地代理的最小 HTTP/1.1 客户端（零依赖）。
// 必须按字节处理 chunked：按 utf8 字符串切分会把中文截坏。
const http = require('http');
const tls = require('tls');

const PROXY = {
  host: process.env.PROXY_HOST || '127.0.0.1',
  port: Number(process.env.PROXY_PORT || 7897),
};

function tunnel(host, port = 443) {
  return new Promise((resolve, reject) => {
    const req = http.request({
      host: PROXY.host, port: PROXY.port, method: 'CONNECT', path: `${host}:${port}`,
      timeout: 20000,
    });
    req.on('connect', (res, socket) => {
      if (res.statusCode !== 200) return reject(new Error('CONNECT ' + res.statusCode));
      const t = tls.connect({ socket, servername: host }, () => resolve(t));
      t.on('error', reject);
    });
    req.on('timeout', () => { req.destroy(); reject(new Error('CONNECT timeout')); });
    req.on('error', reject);
    req.end();
  });
}

function decodeChunked(buf) {
  const parts = [];
  let i = 0;
  while (i < buf.length) {
    const nl = buf.indexOf('\r\n', i);
    if (nl < 0) break;
    const size = parseInt(buf.slice(i, nl).toString('ascii').trim(), 16);
    if (!size || Number.isNaN(size)) break;
    const start = nl + 2;
    parts.push(buf.slice(start, start + size));
    i = start + size + 2;
  }
  return Buffer.concat(parts);
}

async function request(host, pathAndQuery, headers = {}, method = 'GET', bodyBuf = null) {
  const socket = await tunnel(host);
  const lines = [
    `${method} ${pathAndQuery} HTTP/1.1`,
    `Host: ${host}`,
    ...Object.entries(headers).map(([k, v]) => `${k}: ${v}`),
    'connection: close',
    'accept-encoding: identity',
  ];
  if (bodyBuf) lines.push(`content-length: ${bodyBuf.length}`);
  socket.write(lines.join('\r\n') + '\r\n\r\n');
  if (bodyBuf) socket.write(bodyBuf);

  const chunks = [];
  return await new Promise((resolve, reject) => {
    socket.on('data', (d) => chunks.push(d));
    socket.on('end', () => {
      const raw = Buffer.concat(chunks);
      const headEnd = raw.indexOf('\r\n\r\n');
      const head = raw.slice(0, headEnd).toString('utf8').split('\r\n');
      const status = Number(head[0].split(' ')[1]);
      let body = raw.slice(headEnd + 4);
      const chunked = head.some((h) => /^transfer-encoding:\s*chunked/i.test(h));
      if (chunked) body = decodeChunked(body);
      resolve({
        status,
        head,
        headers: Object.fromEntries(head.slice(1).map((h) => {
          const i = h.indexOf(':');
          return [h.slice(0, i).toLowerCase(), h.slice(i + 1).trim()];
        })),
        body,
      });
    });
    socket.on('error', reject);
    setTimeout(() => reject(new Error('timeout')), 30000);
  });
}

module.exports = { request, tunnel, decodeChunked };
