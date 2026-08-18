#!/usr/bin/env python3
"""baseline-concurrent の out/ から、記事に引く数値を出す。

  python3 tools/analyze.py out/baseline-concurrent
"""
import sys, re, bisect, collections, pathlib

d = pathlib.Path(sys.argv[1])

def reload_delay():
    f = d/"reload-times.txt"
    if not f.exists(): return
    reloads = sorted(float(x) for x in f.read_text().split())
    times = []
    for ln in (d/"front-access.log").read_text().splitlines():
        g = ln.split()
        if len(g) > 1 and g[1] == "502":
            times.append(float(g[0]))
    if not (reloads and times): return
    deltas, per = [], collections.Counter()
    for t in times:
        i = bisect.bisect_right(reloads, t) - 1
        if i >= 0:
            deltas.append((t - reloads[i]) * 1000); per[i] += 1
    deltas.sort()
    n = len(deltas)
    print(f"reload {len(reloads)}回 / 502 {len(times)}件")
    print(f"reload からの遅れ ms: min={deltas[0]:.0f} p50={deltas[n//2]:.0f} max={deltas[-1]:.0f}")
    c = sorted(per.values())
    print(f"reload 1回あたりの502: {c} 中央値 {c[len(c)//2]}")
    for i in sorted(per)[:3]:
        ts = sorted(t for t in times if bisect.bisect_right(reloads, t)-1 == i)
        print(f"  reload#{i}: {len(ts)}件 幅 {(ts[-1]-ts[0])*1000:.0f}ms")

def packet_sequence():
    f = d/"loopback.txt"
    if not f.exists(): return
    by_port = collections.defaultdict(list)
    for ln in f.read_text().splitlines():
        m = re.match(r'(\d+\.\d+) IP 127\.0\.0\.1\.(\d+) > 127\.0\.0\.1\.(\d+): Flags \[([^\]]+)\]', ln)
        if not m: continue
        t, s_, d_, fl = float(m.group(1)), m.group(2), m.group(3), m.group(4)
        by_port[s_ if d_ == "8081" else d_].append((t, "front->be" if d_ == "8081" else "be->front", fl, ln))
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
    print(f"FIN → 次リクエスト → RST が取れた接続: {n}")
    print(f"FIN→次リクエスト µs: min={a[0]:.0f} p50={a[n//2]:.0f} max={a[-1]:.0f}")
    print(f"次リクエスト→RST µs: min={b[0]:.0f} p50={b[n//2]:.0f} max={b[-1]:.0f}")
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
    print(f"再送があった行: {len(retried)} 内訳(試行:件数) {dict(sorted(dist.items()))}")
    print(f"request_time 再送なし p50={q(normal,.5):.4f}s p99={q(normal,.99):.4f}s")
    print(f"request_time 再送あり p50={q(retried,.5):.4f}s p99={q(retried,.99):.4f}s")

reload_delay(); packet_sequence(); retries()
