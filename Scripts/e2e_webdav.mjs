// 极简 WebDAV 服务:只实现本仓库同步后端真正用到的三种方法
// (MKCOL 建目录 / GET 读 / PUT 写)+ 强 ETag 乐观并发(deploy 时 If-Match 不匹配回 412)。
// 给 integration_test/sync_auto_merge_test.dart 当「云端」用 —— 那是一条真实的
// HTTP 往返:真 WebDavBackend、真 JSON 序列化、真 ETag。
//
// 用法:
//   node Scripts/e2e_webdav.mjs [port]        # 默认 8099
//   # 模拟器访问宿主机:http://10.0.2.2:8099/
//
// 辅助接口(不是 WebDAV,给测试自己用):
//   GET  /_stats   → { mkcol, gets, puts, rejected, hasFile }
//   POST /_reset   → 清空
import { createServer } from 'node:http';
import { createHash } from 'node:crypto';

const port = Number(process.argv[2] ?? 8099);
const files = new Map();
const stats = { mkcol: 0, gets: 0, puts: 0, rejected: 0 };

const etagOf = (body) =>
  `"${createHash('sha1').update(body).digest('hex')}"`;

const json = (res, status, payload) => {
  res.writeHead(status, { 'content-type': 'application/json' });
  res.end(JSON.stringify(payload));
};

const server = createServer((req, res) => {
  const path = decodeURIComponent(new URL(req.url, 'http://x').pathname);

  if (path === '/_stats') {
    json(res, 200, { ...stats, hasFile: files.has('/DreamMangaReader/sync.json') });
    return;
  }
  if (path === '/_reset') {
    files.clear();
    for (const k of Object.keys(stats)) stats[k] = 0;
    res.writeHead(204).end();
    return;
  }

  // 目录:WebDAV 的 MKCOL。已存在按 405 回(坚果云等也是这么回的)。
  if (path.endsWith('/')) {
    if (req.method === 'MKCOL') {
      stats.mkcol++;
      const exists = [...files.keys()].some((k) => k.startsWith(path));
      res.writeHead(exists ? 405 : 201).end();
      return;
    }
    res.writeHead(405).end();
    return;
  }

  const entry = files.get(path);

  if (req.method === 'GET') {
    stats.gets++;
    if (!entry) {
      res.writeHead(404).end();
      return;
    }
    res.writeHead(200, { 'content-type': 'application/json', etag: entry.etag });
    res.end(entry.body);
    return;
  }

  if (req.method === 'PUT') {
    const ifMatch = req.headers['if-match'];
    if (ifMatch && (!entry || entry.etag !== ifMatch)) {
      stats.rejected++;
      res.writeHead(412).end();
      return;
    }
    const chunks = [];
    req.on('data', (c) => chunks.push(c));
    req.on('end', () => {
      const body = Buffer.concat(chunks).toString('utf8');
      const etag = etagOf(body);
      files.set(path, { body, etag });
      stats.puts++;
      res.writeHead(200, { etag }).end();
    });
    return;
  }

  res.writeHead(405).end();
});

server.listen(port, '0.0.0.0', () => {
  console.log(`E2E WebDAV listening on http://127.0.0.1:${port}/`);
  console.log(`  emulator → http://10.0.2.2:${port}/`);
  console.log(`  stats    → http://127.0.0.1:${port}/_stats`);
});
