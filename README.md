# keepalive reuse race lab

A proxy pools keepalive connections to its backend. When the backend closes one and a busy worker reuses it before noticing, the request gets no response — a sporadic 502 that never reproduces by hand.

This lab reproduces and measures it.

## Run it

```
docker build -t keepalive-lab .
docker run --rm --cap-add=NET_ADMIN --cap-add=NET_RAW -v "$PWD":/lab keepalive-lab bash /lab/run.sh <scenario>
```

Output lands in `out/<scenario>/`. Scenario names are in `run.sh`.

## Results

Each CI job's summary has the aggregated figures for that scenario. Artifacts carry the raw logs.