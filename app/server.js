// A minimal application backend that speaks HTTP/1.1 keepalive, so front pools
// connections to it the same way it pools them to the nginx backend.
//
//   PORT           listen port (default 8081)
//   KEEPALIVE_MS   server.keepAliveTimeout (default: Node's own, 5000)
//   SLOW_MS        milliseconds spent "processing" before responding (default 0)
//   LOG            append one line per request, written the moment it arrives
//
// The log line is written on arrival, before the response, so counting it
// against what the client sent shows whether a retry executed the work twice.
const http = require('http');
const fs = require('fs');

const port = Number(process.env.PORT || 8081);
const slow = Number(process.env.SLOW_MS || 0);
const logPath = process.env.LOG;
const stream = logPath ? fs.createWriteStream(logPath, { flags: 'a' }) : null;

const server = http.createServer((req, res) => {
  let body = 0;
  req.on('data', (c) => { body += c.length; });
  req.on('end', () => {
    if (stream) stream.write(`${Date.now()} ${req.method} ${req.url} ${body} ${req.socket.remotePort}\n`);
    const done = () => { res.writeHead(200, { 'Content-Type': 'text/plain' }); res.end('ok\n'); };
    if (slow > 0) setTimeout(done, slow); else done();
  });
});

if (process.env.KEEPALIVE_MS) {
  server.keepAliveTimeout = Number(process.env.KEEPALIVE_MS);
  server.headersTimeout = server.keepAliveTimeout + 1000;
}

server.listen(port, '127.0.0.1', () => {
  process.stderr.write(`listening on ${port} keepAliveTimeout=${server.keepAliveTimeout}ms slow=${slow}ms\n`);
});

// A deploy stops the process. close() lets in-flight requests finish and drops
// idle connections, which is the closest analogue to nginx's graceful reload.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => server.close(() => process.exit(0)));
}
