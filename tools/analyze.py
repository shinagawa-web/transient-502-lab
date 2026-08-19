#!/usr/bin/env python3
"""Aggregate the figures worth quoting from a scenario's out/ directory.

  python3 tools/analyze.py out/baseline-concurrent
"""
import sys, re, bisect, collections, pathlib

d = pathlib.Path(sys.argv[1])

def reload_delay():
    f = d/"turnover-times.txt"
    if not f.exists(): return
    # a turnover line is "<epoch> <port>"; attribute each 502 to the most recent
    # turnover of the instance the 502 actually came from
    turns = collections.defaultdict(list)
    for ln in f.read_text().splitlines():
        g = ln.split()
        if len(g) == 2: turns[g[1]].append(float(g[0]))
        elif len(g) == 1: turns["?"].append(float(g[0]))
    for v in turns.values(): v.sort()
    times = []
    for ln in (d/"front-access.log").read_text().splitlines():
        g = ln.split()
        if len(g) > 1 and g[1] == "502":
            port = g[3].split(":")[-1].rstrip(",") if len(g) > 3 else "?"
            times.append((float(g[0]), port))
    if not (turns and times): return
    deltas, per = [], collections.Counter()
    for t, port in times:
        seq = turns.get(port) or next(iter(turns.values()))
        i = bisect.bisect_right(seq, t) - 1
        if i >= 0:
            deltas.append((t - seq[i]) * 1000); per[(port, i)] += 1
    deltas.sort()
    n = len(deltas)
    print(f"turnovers {sum(len(v) for v in turns.values())} / 502s {len(times)}")
    print(f"delay after turnover, ms: min={deltas[0]:.0f} p50={deltas[n//2]:.0f} max={deltas[-1]:.0f}")
    c = sorted(per.values())
    print(f"502s per turnover: {c} median {c[len(c)//2]}")
    for key in sorted(per)[:3]:
        port, i = key
        seq = turns[port]
        ts = sorted(t for t, p_ in times if p_ == port and bisect.bisect_right(seq, t)-1 == i)
        print(f"  {port} turnover #{i}: {len(ts)} within {(ts[-1]-ts[0])*1000:.0f}ms")

def packet_sequence():
    f = d/"loopback.txt"
    if not f.exists(): return
    by_port = collections.defaultdict(list)
    for ln in f.read_text().splitlines():
        m = re.match(r'(\d+\.\d+) IP 127\.0\.0\.1\.(\d+) > 127\.0\.0\.1\.(\d+): Flags \[([^\]]+)\]', ln)
        if not m: continue
        t, s_, d_, fl = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        by_port[s_ if d_ in ("8081","8082") else d_].append((t, "front->be" if d_ in ("8081","8082") else "be->front", fl, ln))
    hits, flows = [], []
    for port, ev in by_port.items():
        ev.sort()
        for i, (t, dir_, fl, _) in enumerate(ev):
            if dir_ == "be->front" and "F" in fl:
                for j in range(i+1, len(ev)):
                    t2, d2, fl2, _ = ev[j]
                    if d2 == "front->be" and "P" in fl2:
                        for k in range(j+1, len(ev)):
                            t3, _, fl3, _ = ev[k]
                            if "R" in fl3:
                                hits.append(((t2-t)*1e6, (t3-t2)*1e6))
                                if len(flows) < 10 and len(ev) <= 40:
                                    flows.append(f"# 127.0.0.1:{port} <-> 127.0.0.1:8081\n" + "\n".join(x[3] for x in ev))
                                break
                        break
                break
    if not hits: return
    a = sorted(h[0] for h in hits); b = sorted(h[1] for h in hits)
    n = len(a)
    print(f"connections showing FIN then next request then RST: {n}")
    print(f"FIN to next request, us: min={a[0]:.0f} p50={a[n//2]:.0f} max={a[-1]:.0f}")
    print(f"that request to RST, us: min={b[0]:.0f} p50={b[n//2]:.0f} max={b[-1]:.0f}")
    (d/"loopback-reset-flows.txt").write_text("\n\n".join(flows))

def retries():
    f = d/"front-access.log"
    if not f.exists(): return
    lines = f.read_text().splitlines()
    if not lines or not re.match(r'^\d+\.\d+ ', lines[0]): return
    retried, normal, dist = [], [], collections.Counter()
    for ln in lines:
        g = ln.split()
        if len(g) < 3: continue
        n_att = ln.count("127.0.0.1:808")
        (retried if n_att > 1 else normal).append(float(g[2]))
        if n_att > 1: dist[n_att] += 1
    if not retried: return
    q = lambda v, p: sorted(v)[int(len(v)*p)]
    print(f"lines carrying a retry: {len(retried)} (attempts:count) {dict(sorted(dist.items()))}")
    print(f"request_time without retry p50={q(normal,.5):.4f}s p99={q(normal,.99):.4f}s")
    print(f"request_time with retry    p50={q(retried,.5):.4f}s p99={q(retried,.99):.4f}s")

reload_delay(); packet_sequence(); retries()
