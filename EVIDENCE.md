# Sporadic 502s from keepalive connection reuse

A front nginx pools keepalive connections to a backend. When the backend closes one and a busy worker reuses it before processing the FIN, the request gets no response and returns 502. One of the sporadic 502s that is written off as unreproducible in production.

## Environment

- nginx 1.29.1 (official image, Debian 12.12)
- Linux 6.12.54-linuxkit aarch64 (Docker Desktop on macOS)
- front (`127.0.0.1:8080`, 4 workers, `keepalive 16`) proxying to backend (`127.0.0.1:8081`, 2 workers), both in one container over loopback
- Load: `ab -r -k -c 64 -n 70000`. 3.6 seconds, 19,369 req/s
- The backend is reloaded with `nginx -s reload` every 0.4s: 9 times during the 3.6 seconds of load

The reproduction is `run.sh`, configs are in `conf/`, and each scenario's raw logs land in `out/<scenario>/`. CI re-runs all of this on `ubuntu-latest` and keeps the logs as artifacts.

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

## Scenarios and results

| Scenario | Condition | Requests | 502 | Error log |
|---|---|---|---|---|
| baseline-concurrent | 64-way concurrency + reloads, `proxy_next_upstream off` | 70,000 | 273–305 | same |
| baseline-sequential | One at a time (0.15s apart), same reloads | 400 | 0 | 0 |
| retry-get | Default `proxy_next_upstream`, GET | 70,000 | 0 | 478 |
| retry-post | Default `proxy_next_upstream`, POST | 70,000 | 237 | 237 |
| nonidem-post | `proxy_next_upstream error timeout non_idempotent`, POST | 70,000 | 0 | 405 |
| ka-timeout | `keepalive_timeout 5s` on front's upstream | 70,000 | 303 | 303 |
| backend-noka | Backend `keepalive_timeout 0` (Connection: close per response) | 70,000 | 0 | 0 |
| idle-close | No reload, backend `keepalive_timeout 1s`, load broken every 1.5s | 40,000 | 0 | 0 |
| baseline-20s | 20s of load, 50 reloads (comparison for drain) | 381,087 | 2,236 | 2,236 |
| drain | 20s of load, retire before stopping, 19 swaps | 382,582 | 0 | 0 |

baseline-concurrent was run four times: 273 / 297 / 303 / 305. It moves between runs, so it is a range, not a figure.

## What the runs establish

Concurrency is the condition. The same reloads driven one request at a time produce zero failures in 400 requests. The failure needs a front worker busy enough not to have processed the FIN when it pulls that connection out of the pool. An idle worker handles the FIN first and drops the connection.

Retries remove the 502 without removing the failure. With the default `proxy_next_upstream`, GET sees zero 502s while the error log still records 478 failures.

One client request is not one upstream attempt. With `$upstream_addr` and `$upstream_status` in the access log, a single line carries several attempts:

```
1787042097.147 200 0.002 127.0.0.1:8081, 127.0.0.1:8081, 127.0.0.1:8081, 127.0.0.1:8081 502, 502, 502, 200 GET / HTTP/1.0
```

389 of 70,000 lines carry a retry: 315 at two attempts, 60 at three, 13 at four, one at five. The 478 failed attempts match the error log line for line — an error log line records an attempt, not a request. The default `combined` format omits `$upstream_status`, which is why none of this is visible in practice.

Retries cost latency. `$request_time` is a median of 3ms and p99 of 6ms without a retry, against a median of 5ms, p99 of 27ms and a maximum of 33ms with one.

POST is not retried. The default `proxy_next_upstream` excludes non-idempotent methods, so under identical conditions GET showed zero 502s and POST showed 237. This is one reason 502s appear only on certain endpoints.

Front's upstream `keepalive_timeout` does not help against reloads. 303 with a 5s timeout, inside the baseline spread. A reload sends FIN without waiting on front's intentions, and the window is under a millisecond, not seconds.

Idle timeouts alone produced nothing here. With no reloads, a 1s backend idle timeout and load broken every 1.5s, the result was zero. For a connection to sit idle long enough to time out, the front has to be idle too, and an idle front processes the FIN in time. The two conditions work against each other.

## Mitigations that work, and what they cost

Draining. Bring up a second backend, point front's upstream at it, reload front, and stop the old backend only once the old front workers are gone — the pool belongs to the worker process, so it dies with it. 19 swaps in 20 seconds produced zero failures, against 2,236 over the same span with 50 plain reloads. The pool stays. The cost is procedure: two backends and a config swap. Reloading front also drops client keepalive connections (`ab` aborts here without `-r`); the client-side impact was not measured.

Turning keepalive off on the backend. `keepalive_timeout 0` makes the backend send `Connection: close` with each response, so front never pools. Zero 502s and zero failures. The cost is connections: `TcpActiveOpens` 70,128 against 771, one TCP connection per request. The point of keepalive is given up.

Adding `non_idempotent`. POST gets retried too and 502s go to zero, while 405 failures remain in the error log. No duplicate execution was observed: the backend received exactly 70,000 requests, matching what the client sent, because the connection was already closed when front wrote — the backend never read the request. That does not generalize to a response lost after processing, which this lab cannot produce.

## Signatures collected

The error log splits into two forms. The ratio moves between runs.

```
upstream prematurely closed connection while reading response header from upstream
recv() failed (104: Connection reset by peer) while reading response header from upstream
```

For baseline-concurrent with 297 502s, the split was 287 and 10.

`nstat` deltas, which move with the 502 count without matching it:

```
TcpEstabResets                  307
TcpOutRsts                      297
TcpExtTCPAbortOnData            284
```

tcpdump on loopback, `tcp port 8081`. On a single 4-tuple, the sequence FIN, next request, RST appears in 285 connections. 297 requests failed, so not all of them were captured.

- From the backend's FIN to front's next request: median 904µs, range 3–3,449µs
- From that request to the RST: median 2µs, maximum 7µs

Timing against reloads. Every one of the 297 502s falls 100–107ms after the preceding reload, median 101ms, none earlier than 100ms. The floor held across four runs.

The failures arrive in bursts, not a trickle. Each of the nine reloads produced 24–39 502s, median 34, and each burst fits inside one millisecond: for the first reload, the earliest 502 came 100ms after and the latest 101ms after.

## The same runs on a Linux runner

Everything above was re-run on GitHub Actions `ubuntu-latest` (4 vCPU, 16GB) with the same image, so nginx is identical and the host is the only difference. Run 32120155940; raw logs are in that run's artifacts.

| Scenario | macOS / Docker Desktop | ubuntu-latest |
|---|---|---|
| baseline-concurrent | 273–305 in 70,000 | 63 in 70,000 |
| baseline-sequential | 0 in 400 | 0 in 400 |
| retry-get | 0 502s, 478 in the error log | 0 502s, 29 in the error log |
| retry-post | 237 / 237 | 37 / 37 |
| nonidem-post | 0 502s, 405 errors, no duplicates | 0 502s, 39 errors, no duplicates |
| ka-timeout | 303 (baseline 273–305) | 52 (baseline 63) |
| idle-close | 0 | 0 |
| baseline-20s | 2,236 in 381,087 | 1,022 in 990,500 |
| drain | 0 in 382,582 | 0 in 1,799,678 |

Every conclusion holds. Concurrency is still the condition, retries still hide the failure without removing it, POST is still not retried, the upstream `keepalive_timeout` still does nothing, draining still takes it to zero.

What moves is the rate. The runner produced roughly a quarter of the failures per request, and 2.6 times the throughput in the same 20 seconds, so a scenario fits fewer reloads (four instead of nine during the 3.6s of load).

Two things are worth calling out.

The 100ms floor held. On the runner the delay after a reload was 98–102ms, median 100, against 100–107ms, median 101 on the Mac. A constant that survives a change of host and kernel is more likely to sit in nginx than in scheduling. It still was not traced.

The split between the two error signatures flipped. The Mac produced 287 `prematurely closed` against 10 `recv() failed`; the runner produced 29 against 34. Neither string can be treated as the one to grep for.

The packet-level window narrowed and the RST slowed: FIN to the next request was a median of 619µs against 904µs, and that request to the RST a median of 9µs against 2µs. Both remain well under a millisecond.

## With an application server as the backend

nginx makes a convenient backend — its reload closes idle connections on command — but it is not what sits behind a proxy in production, and its graceful shutdown is unusually well behaved. These scenarios put Node.js 22 there instead. It speaks HTTP/1.1 keepalive, front pools connections to it the same way (40,000 requests over 414 connections), and it closes idle connections on its own 5s timer without coordinating with anyone.

Two instances run on 8081 and 8082 with `max_fails=0`, so retiring one leaves the other serving and nginx does not take either out of rotation.

| Scenario | Requests | 502 | What it shows |
|---|---|---|---|
| app-baseline | 70,000 | 4,997 | Restarting an instance without removing it from the upstream produces mostly `connect() failed (111: Connection refused)` (4,964), with 33 from the race. The same lesson as the nginx side: retire before stopping |
| app-idle-close | 40,000 | 0 | The app's own 1s idle timeout, load broken every 1.5s. Zero, as with the nginx backend |
| app-slow-nonidem | 70,000 | 0 | 50ms of processing, POST, `non_idempotent`, instances stopped with SIGTERM. The backend received exactly 70,000: no duplicates |
| app-slow-kill | 70,000 | 0 | Same, but SIGKILL. The backend received 74,525 |

That last row is the one that matters.

The client sent 70,000 POSTs and saw zero 502s. The backend executed 74,525. About 4,525 requests ran twice, silently, while every client got a 200.

The difference between the two rows is only how the instance dies. Under SIGTERM, Node stops accepting, lets in-flight requests finish and closes idle connections — a request that was read is always answered, so a retry only ever replaces an attempt that never reached the application. Under SIGKILL, a request that has been read and processed loses its response, front retries it on another connection, and the work happens again.

So `non_idempotent` is not safe or unsafe on its own. It is safe exactly to the degree that the backend never dies with a request in flight — which covers a graceful deploy and does not cover a crash, an OOM kill, or a node disappearing.

## What was not determined

- What sets the 100ms floor. Whether it is a timer in nginx or the wait before old workers close their idle connections was not investigated
- What separates the two error signatures. `recv() failed (104)` ran between 3 and 10 occurrences per run against several hundred of the other; the boundary was not traced
- Whether idle-timeout closes surface at a different ratio. They did not at 1s against 1.5s gaps. A large pool with uneven use could in principle leave one connection idle while the front stays busy on others, and that was not built
- What fraction of a real workload dies mid-request. The duplicate rate here (4,525 of 70,000) comes from SIGKILLing an instance every 0.4s and says nothing about production
- Whether other runtimes shut down like Node's `server.close()`. gunicorn's sync worker does not keep connections alive at all, and Puma and php-fpm were not tried
- The client-side cost of draining. Reloading front drops client keepalive connections, and nothing was measured on that side
- The production rate. 0.4% here comes from reloading every 0.4s; a real deploy reloads once
- Why the runner fails about four times less often per request. The rate depends on the host, and neither host was profiled to explain it
- Why the two error signatures land in different proportions on the two hosts
- Bare metal. Neither host is one: a linuxkit VM on macOS, and a cloud VM on Actions

## What is kept in out/

Per scenario: `summary.txt`, `front-error.log` in full, `front-access-non200.log`, `front-access.log.gz`, `nstat.txt`, `ab.log`, `reload-times.txt`, and copies of the configs used.

Packet captures (about 20MB each) are not committed; `run.sh` regenerates them at `out/<scenario>/loopback.pcap`, and CI keeps them as artifacts. `out/baseline-concurrent/loopback-reset-flows.txt` holds every packet line for ten connections that reached RST.

Access logs for `retry-get`, `baseline-concurrent`, `baseline-sequential` and later runs use `$msec $status $request_time $upstream_addr $upstream_status $request`. Earlier scenarios use `combined`.
