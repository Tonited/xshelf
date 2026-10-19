// 诊断脚本：通过本地 HTTP 代理做 CONNECT，验证 x.com 是否可达。
// 用法: node tool/probe_proxy.js [host:port ...]
const http = require('http');
const tls = require('tls');

const proxyPort = Number(process.env.PROXY_PORT || 7897);
const proxyHost = process.env.PROXY_HOST || '127.0.0.1';
const targets = process.argv.slice(2).length
  ? process.argv.slice(2)
  : ['x.com:443', 'api.x.com:443', 'pbs.twimg.com:443'];

function probe(target) {
  return new Promise((resolve) => {
    const [host, portStr] = target.split(':');
    const port = Number(portStr || 443);
    const t0 = Date.now();
    const req = http.request({
      host: proxyHost,
      port: proxyPort,
      method: 'CONNECT',
      path: `${host}:${port}`,
      timeout: 15000,
    });
    req.on('connect', (res, socket) => {
      if (res.statusCode !== 200) {
        resolve({ target, ok: false, note: `CONNECT ${res.statusCode}` });
        socket.destroy();
        return;
      }
      const s = tls.connect({ socket, servername: host }, () => {
        resolve({
          target,
          ok: true,
          ms: Date.now() - t0,
          note: `TLS ${s.getProtocol()} ${s.getPeerCertificate()?.subject?.CN || ''}`,
        });
        s.destroy();
      });
      s.on('error', (e) =>
        resolve({ target, ok: false, ms: Date.now() - t0, note: `TLS ${e.code || e.message}` }));
    });
    req.on('timeout', () => {
      resolve({ target, ok: false, note: 'CONNECT timeout' });
      req.destroy();
    });
    req.on('error', (e) =>
      resolve({ target, ok: false, note: `CONNECT ${e.code || e.message}` }));
    req.end();
  });
}

(async () => {
  console.log(`proxy ${proxyHost}:${proxyPort}`);
  for (const t of targets) {
    const r = await probe(t);
    console.log(
      `${r.ok ? 'OK  ' : 'FAIL'} ${r.target.padEnd(20)} ${r.ms ?? ''}ms ${r.note || ''}`,
    );
  }
})();
