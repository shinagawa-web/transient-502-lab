# Sporadic 502s from keepalive connection reuse

A proxy pools keepalive connections to its backend. When the backend closes one and a busy worker reuses it before noticing, the request gets no response and the client sees a 502. One of the sporadic 502s that is written off as unreproducible in production.

This file records what each scenario establishes. It does not carry figures: the counts move between runs, and copying them here only produces a file that disagrees with the runs. Every run's job summary has the aggregated numbers and its artifacts have the raw logs.

## Setup

nginx 1.29.1 in front, two Node.js 22 instances behind it on 8081 and 8082, all on loopback in one container. Load is `ab -r -k -c 64 -n 70000` at 64-way concurrency.

The backend is an application server rather than another nginx because that is what sits there in practice, and because how it shuts down turns out to decide whether retries duplicate work — something a second nginx cannot show, since its reload always answers what it has read.

Two instances are not there to keep the service up. They are there so one can be disturbed while the other answers, which is what makes the reuse race measurable instead of drowned in a plain outage. `max_fails=0` keeps nginx from taking a disturbed instance out of rotation, so what is measured is the race and not passive health checks. That is also why several scenarios show connection-refused: only `drain` takes the instance out of the upstream before touching it.

The default disturbance is `GET /__close-idle`, which makes the app drop its idle keepalive connections at once — what a process replacement does to the proxy's pool, without taking the listener away.

## What each scenario establishes

| Scenario | Establishes |
|---|---|
| baseline-concurrent | The failure reproduces: closing idle connections under concurrency produces 502s in bursts, a few milliseconds after the close |
| baseline-sequential | Concurrency is the condition. The same closes, driven one request at a time, produce essentially none — which is why retrying by hand never reproduces it |
| retry-get | The default `proxy_next_upstream` retries idempotent methods, so the 502 count understates the failures. The error log keeps the real count, and the access log shows the retry once `$upstream_status` is in the format |
| retry-post | Non-idempotent methods are not retried, so their failures surface as 502s |
| nonidem-post | Adding `non_idempotent`, and nothing else, takes those 502s to zero. Differs from retry-post only by the flag |
| ka-timeout | An upstream `keepalive_timeout` does not help. It governs how long the proxy intends to hold an idle connection, and the backend closes without waiting on that |
| idle-close | An idle timeout alone produces nothing. For a connection to sit idle long enough to time out, the proxy has to be idle too, and an idle proxy notices the FIN in time |
| backend-noka | Answering `Connection: close` removes the failure entirely, at one TCP connection per request |
| drain | Taking the instance out of the upstream before stopping it produces neither 502s nor duplicates. The pool belongs to the worker process, so it dies with it |
| deploy-restart | Restarting an instance without draining it produces mostly connection-refused rather than the race |
| slow-term | A graceful SIGTERM duplicates nothing and does not finish either: `close()` waits for connections that never go idle under load, so the instance sits unreachable |
| slow-term-timeout | The kill timeout that deployments add to make shutdown finish duplicates work: the backend receives more requests than the client sent, while every client sees a 200 |
| slow-kill | The same failure without the wait, at a higher rate |

## What follows from them

Concurrency is the condition, and the standard reproduction attempt removes it.

The failure is recorded, one layer over from where people look. It appears in the error log as `upstream prematurely closed connection while reading response header from upstream` or `recv() failed (104: Connection reset by peer) while reading response header from upstream`, and which of the two dominates changes between runs, so neither is the one to grep for.

Method does not decide whether the failure happens, only whether it surfaces. Idempotent methods are retried and the client sees a 200; non-idempotent ones are not.

`non_idempotent` is neither safe nor unsafe on its own. It is safe exactly to the degree that the backend never dies holding a request — which draining guarantees, and a kill timeout, a crash or an OOM kill do not.

Keeping the pool, avoiding an outage and avoiding duplicate execution at the same time requires taking the instance out of the upstream first. Nothing else in these scenarios achieves all three.

## What was not determined

- What separates the two error signatures. Which one dominates moves between runs and the boundary was not traced
- Whether idle-timeout closes surface at a different ratio of timeout to traffic gap. They did not at 1s against 1.5s
- What fraction of a real workload dies mid-request. The duplicate counts here come from disturbing an instance every 0.4s and say nothing about production
- Whether other runtimes shut down like Node's `close()`. gunicorn's sync worker does not keep connections alive at all; Puma and php-fpm were not tried
- The client-side cost of draining, which reloads the proxy and drops client keepalive connections
- Bare metal. The host is a cloud VM on GitHub Actions

## What is kept in out/

Per scenario: `summary.txt`, `front-error.log` in full, `front-access-non200.log`, `front-access.log.gz`, `backend-access.log`, `nstat.txt`, `ab.log`, `turnover-times.txt`, and copies of the config and the app used. Packet captures are regenerated by `run.sh` and kept as CI artifacts rather than committed. `tools/analyze.py` produces the timing, retry and duplicate figures.
