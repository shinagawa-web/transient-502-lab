# keepalive reuse race lab

A proxy pools keepalive connections to its backend. When the backend closes one and the proxy reuses it before noticing, the request gets no response and the client sees a 502. This is one of the sporadic 502s that people give up on because it never reproduces by hand.

This lab reproduces it and measures which mitigations move it.

`EVIDENCE.md` records what each scenario establishes. The numbers live in the CI runs: each job's summary carries the aggregated figures and its artifacts carry the raw logs, so nothing here has to be kept in sync by hand.

## Run it

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

Output lands in `out/<scenario>/`.

## Scenarios

| Name | What it shows |
|---|---|
| baseline-concurrent | The reproduction: 64-way concurrency against instances losing their idle connections |
| baseline-sequential | One request at a time. Concurrency is the condition |
| retry-get | Default `proxy_next_upstream`, GET. Retries hide the 502 |
| retry-post | Default `proxy_next_upstream`, POST. Not retried, so it stays visible |
| nonidem-post | retry-post plus `non_idempotent`, nothing else changed |
| ka-timeout | `keepalive_timeout 5s` on the upstream. Does not help |
| idle-close | No turnover; the app's own idle timeout closes connections |
| backend-noka | The app answers `Connection: close`, so nothing is pooled |
| drain | Retire the instance from the upstream before stopping it |
| deploy-restart | Restart it without retiring it first |
| slow-term | 50ms of processing, SIGTERM, `non_idempotent`. `close()` never finishes under load |
| slow-term-timeout | Same, with the kill timeout that deployments add. Retries duplicate work |
| slow-kill | Same, killed outright |

## Setup

nginx 1.29.1 in front, two Node.js 22 instances behind it on 8081 and 8082, all on loopback in one container. Load comes from `ab`.

The backend is an application server rather than another nginx, because that is what sits there in practice and because how it shuts down turns out to decide whether retries duplicate work.

Two instances are not there to keep the service up. They are there so one can be disturbed while the other answers, which is what makes the race measurable instead of drowned in a plain outage. `max_fails=0` keeps nginx from taking a disturbed instance out of rotation, so what is measured is the race and not passive health checks — which is also why several scenarios show connection-refused. Only `drain` takes the instance out of the upstream first.

The default turnover is `GET /__close-idle`, which makes the app drop its idle keepalive connections at once: the same thing a process replacement does to the proxy's pool, without taking the listener away.

`conf/` holds the proxy configs, `app/server.js` is the backend, `run.sh` drives the scenarios, `tools/analyze.py` produces the timing and retry figures.

## About the numbers

They move between runs and between hosts, so treat them as magnitudes rather than constants. CI runs everything on GitHub Actions `ubuntu-latest` (4 vCPU, 16GB), with nginx and Node pinned through their official images.
