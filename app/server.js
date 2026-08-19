// An application backend that speaks HTTP/1.1 keepalive, so the proxy in front
// pools connections to it the way it pools them to any app server.
//
//   PORT           listen port
//   KEEPALIVE_MS   server.keepAliveTimeout (default: Node's own, 5000)
//   SLOW_MS        milliseconds spent "processing" before responding (default 0)
//   NO_KEEPALIVE   respond with Connection: close, so the proxy never pools
//   SHUTDOWN_KILL_MS  exit this long after SIGTERM even if close() has not
//                     returned -- the timeout operators add when a graceful
//                     shutdown will not finish
//   LOG            append one line per request, written the moment it arrives
//
// The log line is written on arrival, before the response, so counting it
// against what the client sent shows whether a retry executed the work twice.
//
// A request to /__close-idle drops every idle keepalive connection at once,
// which is what a process replacement does to a proxy's pool, without taking
// the listener away. That separates the race from a plain outage.
const http = require('http');
const fs = require('fs');

const port = Number(process.env.PORT || 8081);
const slow = Number(process.env.SLOW_MS || 0);
const noKeepalive = process.env.NO_KEEPALIVE === '1';
const logPath = process.env.LOG;
const stream = logPath ? fs.createWriteStream(logPath, { flags: 'a' }) : null;

const server = http.createServer((req, res) => {
  if (req.url === '/__close-idle') {
    res.writeHead(200).end('closing\n');
    server.closeIdleConnections();
    return;
  }
  let body = 0;
  req.on('data', (c) => { body += c.length; });
  req.on('end', () => {
    if (stream) stream.write(`${Date.now()} ${req.method} ${req.url} ${body} ${req.socket.remotePort}\n`);
    const done = () => {
      const payload = 'ok\n';
      // Content-Length rather than chunked, so both hops can reuse connections
      const headers = { 'Content-Type': 'text/plain', 'Content-Length': Buffer.byteLength(payload) };
      if (noKeepalive) headers['Connection'] = 'close';
      res.writeHead(200, headers);
      res.end(payload);
    };
    if (slow > 0) setTimeout(done, slow); else done();
  });
});

if (process.env.KEEPALIVE_MS) {
  server.keepAliveTimeout = Number(process.env.KEEPALIVE_MS);
  server.headersTimeout = server.keepAliveTimeout + 1000;
}

server.listen(port, '127.0.0.1', () => {
  process.stderr.write(`listening on ${port} keepAliveTimeout=${server.keepAliveTimeout}ms slow=${slow}ms noKeepalive=${noKeepalive}\n`);
});

// A deploy stops the process. Dropping idle connections first and then closing
// lets in-flight requests finish without waiting on pooled connections that are
// sitting idle -- close() on its own waits for those, which is an outage.
// SIGKILL from outside does neither.
for (const sig of ['SIGTERM', 'SIGINT']) {
  process.on(sig, () => {
    server.closeIdleConnections();
    server.close(() => process.exit(0));
    const killMs = Number(process.env.SHUTDOWN_KILL_MS || 0);
    if (killMs > 0) setTimeout(() => process.exit(0), killMs).unref();
  });
}
