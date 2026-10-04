// Test double for the tracker API, used only by scripts/tray/tests.ps1.
// Usage: node fake-backend.mjs <port> <scenario.json>
// The scenario file is re-read on every request, so a test can change it live.
// Every POST path is appended to <scenario.json>.posts.
import fs from 'node:fs';
import http from 'node:http';

const [port, scenarioFile] = [Number(process.argv[2]), process.argv[3]];

http.createServer((request, response) => {
  const scenario = JSON.parse(fs.readFileSync(scenarioFile, 'utf8'));
  const url = new URL(request.url, 'http://x');
  if (request.method === 'POST') fs.appendFileSync(`${scenarioFile}.posts`, `${url.pathname}${url.search}\n`);
  response.setHeader('content-type', 'application/json');
  if (url.pathname === '/api/health') return response.end(JSON.stringify(scenario.health));
  if (url.pathname === '/api/overview' || url.pathname === '/api/refresh') {
    const overview = scenario.overview[url.searchParams.get('provider')];
    return response.end(JSON.stringify(overview ?? {}));
  }
  response.statusCode = 404;
  response.end('{}');
}).listen(port, '127.0.0.1');
