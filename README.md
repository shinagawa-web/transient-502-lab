# keepalive reuse race lab

A reverse proxy pools keepalive connections to its upstream. When the backend closes one and the proxy reuses it before noticing, the request gets no response and the client sees a 502. This is one of the sporadic 502s that people give up on because it never reproduces by hand.

This lab reproduces it and measures which mitigations actually move it.

Results are in `EVIDENCE.md`. Raw logs from CI runs are kept as workflow artifacts.

## Run it

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh baseline-concurrent
```

Output lands in `out/<scenario>/`.

## Scenarios

| Name | What it shows |
|---|---|
| baseline-concurrent | 64-way concurrency, backend reloaded every 0.4s. The plain reproduction |
| baseline-sequential | One request at a time, same reloads. Concurrency is the condition |
| retry-get | Default `proxy_next_upstream`, GET load. Retries hide the 502 |
| retry-post | Same config, POST load. Non-idempotent methods are not retried |
| nonidem-post | `non_idempotent` added, so POST is retried too |
| ka-timeout | `keepalive_timeout 5s` on front's upstream. Does it help against reloads |
| idle-close | No reload, backend idle timeout 1s. Does it happen outside deploys |
| baseline-20s | 20s of load, 50 reloads. Comparison point for drain |
| drain | Retire the backend from the upstream before stopping it |

## Setup

A front nginx (`127.0.0.1:8080`, 4 workers, `keepalive 16`) proxies to a backend nginx (`127.0.0.1:8081`, 2 workers). Both run in one container so tcpdump on loopback sees the whole exchange. Load comes from `ab`.

`conf/` holds the configs, `run.sh` drives the scenarios, `tools/analyze.py` aggregates what the logs and captures contain.

## About the numbers

They move with the environment. The first measurements in `EVIDENCE.md` were taken on Docker Desktop on macOS, which puts a linuxkit VM in the path. CI re-runs everything on GitHub Actions `ubuntu-latest` (4 vCPU, 16GB). nginx is pinned to 1.29.1 through the official image, so the host is the only variable between the two.
