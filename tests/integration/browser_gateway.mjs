import { createServer } from 'node:http';
import { randomUUID } from 'node:crypto';
import { readFile } from 'node:fs/promises';
import { resolve, sep, extname } from 'node:path';
import { handler } from '../../infra/terraform/dev/request-proxy.mjs';
import { parseAndVerify } from '../../infra/terraform/dev/jwt-authorizer/jwt.mjs';

if (process.env.GITHUB_ACTIONS !== 'true' || !process.env.JWT_SECRET) {
  throw new Error('Use only with the disposable GitHub Actions stack');
}
process.env.BACKEND_PRIVATE_IP = '127.0.0.1';
const secret = Buffer.from(process.env.JWT_SECRET);
const root = resolve(process.argv[2]);
const publicPaths = new Set(['/api/v1/auth/login', '/api/v1/auth/refresh', '/api/v1/auth/logout']);
const mime = {
  '.html': 'text/html', '.js': 'text/javascript', '.json': 'application/json',
  '.wasm': 'application/wasm', '.png': 'image/png', '.svg': 'image/svg+xml',
};

createServer(async (request, response) => {
  try {
    const url = new URL(request.url, 'http://127.0.0.1');
    if (url.pathname.startsWith('/api/v1/')) {
      const identity = parseAndVerify(request.headers.authorization?.replace(/^Bearer /, ''), secret);
      if (!identity && !publicPaths.has(url.pathname)) {
        response.writeHead(401, {'content-type': 'application/json'}).end('{"error":"unauthorized"}');
        return;
      }
      const chunks = [];
      for await (const chunk of request) chunks.push(chunk);
      const result = await handler({
        rawPath: url.pathname,
        rawQueryString: url.search.slice(1),
        headers: request.headers,
        requestContext: {
          requestId: randomUUID(), http: { method: request.method }, authorizer: { lambda: identity },
        },
        body: chunks.length ? Buffer.concat(chunks).toString('utf8') : undefined,
      });
      response.writeHead(result.statusCode, result.headers).end(
        Buffer.from(result.body, result.isBase64Encoded ? 'base64' : 'utf8'),
      );
      return;
    }
    const path = resolve(root, '.' + decodeURIComponent(url.pathname === '/' ? '/index.html' : url.pathname));
    if (!path.startsWith(root + sep)) {
      response.writeHead(404).end();
      return;
    }
    const file = await readFile(path);
    response.writeHead(200, {'content-type': mime[extname(path)] || 'application/octet-stream'}).end(file);
  } catch (error) {
    response.writeHead(error.code === 'ENOENT' ? 404 : 500).end();
  }
}).listen(5173, '127.0.0.1');
