# Sporadic 502s from keepalive connection reuse

A proxy pools keepalive connections to its backend. When the backend closes one and a busy worker reuses it before noticing, the request gets no response and the client sees a 502. One of the sporadic 502s that is written off as unreproducible in production.

## Setup

- nginx 1.29.1 in front, Node.js 22 behind it (`app/server.js`), all on loopback in one container
- Two app instances on 8081 and 8082, both in the upstream with `keepalive 16` and `max_fails=0`
- Load: `ab -r -k -c 64 -n 70000`, roughly 3-5 seconds
- Turnover, unless a scenario says otherwise: `GET /__close-idle` against one instance every 0.4s, alternating. The app drops its idle keepalive connections at once, which is what a process replacement does to the proxy's pool, without taking the listener away

Two instances are not there to keep the service up. They are there so that one can be disturbed while the other still answers, which is what makes the reuse race measurable instead of drowned in a plain outage. nginx keeps sending to a stopped instance, because `max_fails=0` turns off passive health checks — leaving them on made both instances drop out and produced `no live upstreams` instead of the race. This is why several scenarios below show connection-refused: only `drain` takes the instance out of the upstream before touching it.

"Turnover" counts those disturbance events. The count differs between scenarios because each style takes a different amount of time — SIGTERM waits, SIGKILL is instant — so figures are compared per turnover, not as totals.

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

## Scenarios and results

| Scenario | Requests | 502 | Backend received | Turnovers |
|---|---|---|---|---|
| baseline-concurrent | 70,000 | 213 | 69,787 | 13 |
| baseline-sequential | 400 | 0–1 | 400 | ~145 |
| retry-get | 70,000 | 0 | 70,000 | 11 |
| retry-post | 70,000 | 179 | 69,821 | 11 |
| ka-timeout | 70,000 | 170 | 69,830 | 11 |
| idle-close | 40,000 | 0 | 40,000 | 0 |
| backend-noka | 70,000 | 0 | 70,000 | 11 |
| drain | 69,739 | 0 | 69,739 | 5 |
| deploy-restart | 70,000 | 1,426 | 68,573 | 12 |
| slow-term | 70,000 | 0 | 70,000 | 4 |
| slow-term-timeout | 70,000 | 21 | 70,624 | 26 |
| slow-kill | 70,000 | 0 | 73,862 | 146 |

## What the runs establish

Concurrency is the condition. Sequential requests with 145 turnovers produced 0, 0 and 1 failures across three runs; 64-way concurrency with 13 turnovers produced 213. Per turnover that is roughly 0.005 against 16. This is why the failure will not reproduce by hand: retrying one request at a time removes the condition.

The failure is recorded, one layer over from where people look, in two forms whose ratio moves between runs:

```
upstream prematurely closed connection while reading response header from upstream
recv() failed (104: Connection reset by peer) while reading response header from upstream
```

For the baseline run with 213 502s, the split was 204 and 9.

The window is under a millisecond. On a single 4-tuple, tcpdump shows the backend's FIN, then the proxy's next request a median of 1,145µs later (range 21–3,301µs), then the RST a median of 2µs after that (maximum 29µs), in 155 connections.

Failures arrive in bursts at the moment connections are closed. 502s land 3–12ms after a turnover, median 4ms, 15–20 per turnover, each burst inside 2–4ms.

Retries remove the 502 without removing the failure. With the default `proxy_next_upstream`, GET saw zero 502s while the error log still recorded 177 failures. One client request is not one upstream attempt, and the access log says so once `$upstream_addr` and `$upstream_status` are in the format:

```
1787042097.147 200 0.002 127.0.0.1:8081, 127.0.0.1:8081 502, 200 GET / HTTP/1.0
```

All 177 retried lines took two attempts. The default `combined` format omits `$upstream_status`, which is why none of this is visible in practice. Retries cost latency: `$request_time` was a median of 2ms and p99 of 5ms without a retry, against 4ms and 14ms with one.

POST is not retried, so its failures stay visible: 179 502s under conditions where GET showed none. This is why 502s appear on some endpoints and not others.

The upstream `keepalive_timeout` does not help. 170 against a baseline of 213, run-to-run noise. It governs how long the proxy intends to hold an idle connection, and the backend closes without waiting on that.

Idle timeouts alone produced nothing. With no turnover, a 1s app-side keepAliveTimeout and load broken every 1.5s, the result was zero. For a connection to sit idle long enough to time out, the proxy has to be idle too, and an idle proxy notices the FIN in time.

Turning keepalive off on the backend removes the failure entirely, at one TCP connection per request instead of a pool.

## Stopping an instance: four ways, four outcomes

All four disturb one instance while the other serves. Only `drain` takes it out of the upstream first.

| Style | Turnovers | Duplicates per turnover | Connection-refused per turnover |
|---|---|---|---|
| SIGTERM alone | 4 | 0 | ~1,600 |
| SIGTERM, killed after 2s | 26 | 24 | ~360 |
| SIGKILL | 146 | 26 | ~3 |
| drain, then stop | 5 | 0 | 0 |

SIGTERM alone does not duplicate anything, and does not finish either. `server.close()` waits for connections to end, and under sustained load they never go idle, so the process sat for tens of seconds — four turnovers in a minute, with the instance unreachable for most of it.

That is why deployments add a kill timeout. Adding one gets the process to exit, and takes 70,000 client requests to 70,624 at the backend: about 624 requests executed twice, silently, while the clients saw 200.

SIGKILL is the same failure without the wait: 73,862 against 70,000, about 3,862 duplicates.

Draining is the only one with neither. Once the instance is out of the upstream, no new requests arrive, its connections go idle, `close()` returns immediately, and nothing is in flight to lose.

So `non_idempotent` is not safe or unsafe on its own. It is safe exactly to the degree that the backend never dies holding a request — which a drained shutdown guarantees and a kill timeout, a crash or an OOM kill do not.

Restarting an instance without draining it produces mostly a plain outage rather than the race: 1,426 502s, of which 1,363 were `connect() failed (111: Connection refused)`.

## What was not determined

- What separates the two error signatures. The ratio moved between runs and the boundary was not traced
- Whether idle-timeout closes surface at a different ratio of timeout to traffic gap. They did not at 1s against 1.5s
- What fraction of a real workload dies mid-request. The duplicate rates here come from disturbing an instance every 0.4s and say nothing about production
- Whether other runtimes shut down like Node's `close()`. gunicorn's sync worker does not keep connections alive at all; Puma and php-fpm were not tried
- The client-side cost of draining, which reloads the proxy and drops client keepalive connections
- Bare metal. The host is Docker Desktop on macOS, or a cloud VM on GitHub Actions

## What is kept in out/

Per scenario: `summary.txt`, `front-error.log` in full, `front-access-non200.log`, `front-access.log.gz`, `backend-access.log`, `nstat.txt`, `ab.log`, `turnover-times.txt`, and copies of the config and the app used.

Packet captures (about 20MB each) are not committed; `run.sh` regenerates them and CI keeps them as artifacts. `tools/analyze.py` produces the timing and retry figures quoted above.
