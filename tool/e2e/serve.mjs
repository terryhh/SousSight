// Minimal static file server for a Flutter web build directory. No
// dependencies, bound to localhost only, no caching, SPA fallback to index.html.
//
//   node serve.mjs <build-dir> <port>
import { createServer } from 'node:http';
import { createReadStream, statSync } from 'node:fs';
import { extname, join, normalize, resolve, sep } from 'node:path';

const root = resolve(process.argv[2] ?? 'build/web');
const port = Number(process.argv[3] ?? 8787);

const types = {
  '.html': 'text/html; charset=utf-8',
  '.js': 'text/javascript; charset=utf-8',
  '.mjs': 'text/javascript; charset=utf-8',
  '.json': 'application/json; charset=utf-8',
  '.wasm': 'application/wasm',
  '.css': 'text/css; charset=utf-8',
  '.png': 'image/png',
  '.jpg': 'image/jpeg',
  '.jpeg': 'image/jpeg',
  '.svg': 'image/svg+xml',
  '.ico': 'image/x-icon',
  '.otf': 'font/otf',
  '.ttf': 'font/ttf',
  '.woff2': 'font/woff2',
  '.bin': 'application/octet-stream',
  '.frag': 'application/octet-stream',
};

function fileFor(urlPath) {
  let decoded;
  try {
    decoded = decodeURIComponent(urlPath.split('?')[0]);
  } catch {
    return null; // malformed escape: never serve it, never crash
  }
  const candidate = normalize(join(root, decoded));
  if (candidate !== root && !candidate.startsWith(root + sep)) return null;
  try {
    const stat = statSync(candidate);
    if (stat.isFile()) return candidate;
    if (stat.isDirectory()) {
      const index = join(candidate, 'index.html');
      if (statSync(index).isFile()) return index;
    }
  } catch {
    // fall through
  }
  return null;
}

const server = createServer((req, res) => {
  let file = fileFor(req.url ?? '/');
  // Flutter routes (e.g. /?recipe=...) fall back to the app shell, but a
  // missing asset is a real 404 so the journey notices it.
  const path = (req.url ?? '/').split('?')[0];
  if (!file && !extname(path) && !path.includes('%')) file = join(root, 'index.html');
  if (!file) {
    res.writeHead(404, { 'content-type': 'text/plain' });
    res.end('not found');
    return;
  }
  res.writeHead(200, {
    'content-type': types[extname(file)] ?? 'application/octet-stream',
    'cache-control': 'no-store',
    // Same security headers as firebase.json hosting, so the browser treats
    // the local build like the deployed one (no COOP/COEP there either).
    'permissions-policy': 'camera=(self), microphone=(self), geolocation=(self)',
    'x-content-type-options': 'nosniff',
    'content-security-policy': "frame-ancestors 'self'",
    'referrer-policy': 'strict-origin-when-cross-origin',
  });
  createReadStream(file).pipe(res);
});
server.listen(port, 'localhost', () => {
  // Port 0 picks a free port; print the real one.
  console.log(`serving ${root} on http://localhost:${server.address().port}`);
});
