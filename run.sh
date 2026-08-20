#!/usr/bin/env bash
# Reproduces the keepalive reuse race and compares mitigations.
#
#   ./run.sh <scenario>
#
# The backend is an application server (Node.js, app/server.js), two instances
# on 8081 and 8082, which is what sits behind a proxy in practice.
#
# Unless a scenario says otherwise, the turnover is /__close-idle every 0.4s:
# the app drops its idle keepalive connections at once, the way a process
# replacement does to the proxy's pool, without taking the listener away.
#
#   baseline-concurrent  64-way concurrency. The reproduction
#   baseline-sequential  one request at a time. Concurrency is the condition
#   retry-get            default proxy_next_upstream, GET. Retries hide it
#   retry-post           default proxy_next_upstream, POST. Not retried
#   nonidem-post         retry-post plus non_idempotent, changing nothing else
#   ka-timeout           keepalive_timeout 400ms on the upstream. Does it help
#   idle-close           no turnover; the app's own 1s idle timeout closes them
#   backend-noka         the app answers Connection: close, so nothing is pooled
#   drain                retire an instance from the upstream before stopping it
#   deploy-restart       restart an instance without retiring it first
#   slow-term            50ms of processing, SIGTERM turnover, non_idempotent.
#                        close() waits for connections that never go idle
#   slow-term-timeout    same, but the process exits 2s after SIGTERM regardless
#   slow-kill            same, but SIGKILL
#
# Everything is kept under out/<scenario>/.
set -uo pipefail
sc="${1:?scenario}"
cd /lab
o="out/$sc"; rm -rf "$o"; mkdir -p "$o" run

front_conf=conf/front.conf
turnover=close-idle      # close-idle | none | drain | restart | signal
signal=TERM
load=get
turnover_duration=60
app_keepalive=""
app_slow=0
app_nokeepalive=0
app_shutdown_kill=0

case "$sc" in
  baseline-concurrent) ;;
  baseline-sequential) load=sequential ;;
  baseline-sequential-c1) load=sequential_c1; turnover_duration=300 ;;
  baseline-sequential-noturnover) load=sequential_c1; turnover=none ;;
  baseline-concurrent-noturnover) turnover=none ;;
  retry-get)      front_conf=conf/front-retry.conf ;;
  retry-post)     front_conf=conf/front-retry.conf; load=post ;;
  nonidem-post)   front_conf=conf/front-nonidem.conf; load=post ;;
  ka-timeout)     front_conf=conf/front-ka-timeout.conf ;;
  idle-close)     turnover=none; app_keepalive=1000; load=bursty ;;
  backend-noka)   app_nokeepalive=1 ;;
  drain)          turnover=drain ;;
  deploy-restart) turnover=restart ;;
  slow-term)      front_conf=conf/front-nonidem.conf; load=post; app_slow=50; turnover=signal; signal=TERM ;;
  slow-term-timeout) front_conf=conf/front-nonidem.conf; load=post; app_slow=50; turnover=signal; signal=TERM; app_shutdown_kill=2000 ;;
  slow-kill)      front_conf=conf/front-nonidem.conf; load=post; app_slow=50; turnover=signal; signal=KILL ;;
  *) echo "unknown scenario: $sc"; exit 2 ;;
esac

start_app() { # port
  PORT="$1" SLOW_MS="$app_slow" KEEPALIVE_MS="$app_keepalive" NO_KEEPALIVE="$app_nokeepalive" \
    SHUTDOWN_KILL_MS="$app_shutdown_kill" LOG="/lab/$o/backend-access.log" node /lab/app/server.js 2>>"$o/backend-error.log" &
  echo $! > "run/app-$1.pid"
}
stop_app() { # port signal
  [ -f "run/app-$1.pid" ] || return 0
  kill -"${2:-TERM}" "$(cat "run/app-$1.pid")" 2>/dev/null
  wait "$(cat "run/app-$1.pid")" 2>/dev/null
  rm -f "run/app-$1.pid"
}

cp "$front_conf" app/server.js "$o/"
sed "s|/lab/out/|/lab/$o/|g" "$front_conf" > run/front.conf
sed "s|    server 127.0.0.1:8082 max_fails=0;||" run/front.conf > run/front-only-a.conf
sed "s|    server 127.0.0.1:8081 max_fails=0;||" run/front.conf > run/front-only-b.conf

start_app 8081; start_app 8082; sleep 1
nginx -c /lab/run/front.conf -p /lab & sleep 1

tcpdump -i lo -n -s 128 "(tcp port 8081 or tcp port 8082) and (tcp[tcpflags] & (tcp-fin|tcp-rst|tcp-push) != 0)" \
  -w "$o/loopback.pcap" 2>"$o/tcpdump.log" &
tcpdump_pid=$!
sleep 1
nstat -n

turn() { echo "$(date +%s.%N) $1" >> "$o/turnover-times.txt"; }

case "$turnover" in
  close-idle)
    ( end=$((SECONDS + turnover_duration)); port=8081
      while [ $SECONDS -lt $end ]; do
        turn "$port"; curl -s -o /dev/null "http://127.0.0.1:$port/__close-idle"
        [ "$port" = "8081" ] && port=8082 || port=8081
        sleep 0.4
      done ) & turnover_pid=$! ;;
  signal)
    ( end=$((SECONDS + 60)); port=8081
      while [ $SECONDS -lt $end ]; do
        turn "$port"; stop_app "$port" "$signal"; start_app "$port"
        [ "$port" = "8081" ] && port=8082 || port=8081
        sleep 0.4
      done ) & turnover_pid=$! ;;
  restart)
    ( end=$((SECONDS + 60)); port=8081
      while [ $SECONDS -lt $end ]; do
        turn "$port"; stop_app "$port" TERM; start_app "$port"
        [ "$port" = "8081" ] && port=8082 || port=8081
        sleep 0.4
      done ) & turnover_pid=$! ;;
  drain)
    # Take the instance out of the upstream, reload the proxy so its old workers
    # (and their pools) go away, and only then stop the process.
    ( end=$((SECONDS + 60)); port=8081
      while [ $SECONDS -lt $end ]; do
        if [ "$port" = "8081" ]; then cp run/front-only-b.conf run/front.conf
        else cp run/front-only-a.conf run/front.conf; fi
        nginx -c /lab/run/front.conf -p /lab -s reload 2>>"$o/reload.log"
        sleep 0.5
        stop_app "$port" TERM; start_app "$port"
        cp run/front-only-a.conf run/front.conf   # placeholder, restored below
        sed "s|/lab/out/|/lab/$o/|g" "$front_conf" > run/front.conf
        nginx -c /lab/run/front.conf -p /lab -s reload 2>>"$o/reload.log"
        turn "$port"
        [ "$port" = "8081" ] && port=8082 || port=8081
        sleep 0.4
      done ) & turnover_pid=$! ;;
  none) turnover_pid="" ;;
esac

case "$load" in
  get)  ab -r -k -c 64 -n 70000 -s 30 http://127.0.0.1:8080/ > "$o/ab.log" 2>&1 ;;
  post) printf 'x=1' > run/post.txt
        ab -r -k -c 64 -n 70000 -s 30 -p run/post.txt -T application/x-www-form-urlencoded \
           http://127.0.0.1:8080/ > "$o/ab.log" 2>&1 ;;
  sequential)
        for i in $(seq 1 400); do
          curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/ >> "$o/sequential-codes.txt"
          sleep 0.15
        done ;;
  sequential_c1)
        ab -r -k -c 1 -n 70000 -s 30 http://127.0.0.1:8080/ > "$o/ab.log" 2>&1 ;;
  bursty)
        for round in $(seq 1 20); do
          ab -r -k -c 64 -n 2000 -s 30 http://127.0.0.1:8080/ >> "$o/ab.log" 2>&1
          sleep 1.5
        done ;;
esac

[ -n "${turnover_pid:-}" ] && { kill $turnover_pid 2>/dev/null; wait $turnover_pid 2>/dev/null; }
nstat > "$o/nstat.txt"
sleep 1
kill $tcpdump_pid 2>/dev/null; wait $tcpdump_pid 2>/dev/null
nginx -c /lab/run/front.conf -p /lab -s quit 2>/dev/null
stop_app 8081; stop_app 8082
sleep 1

{
  echo "scenario: $sc"
  echo "front: $front_conf / turnover: $turnover${signal:+ ($signal)} / load: $load / app: keepalive=${app_keepalive:-default} slow=${app_slow}ms no-keepalive=${app_nokeepalive} shutdown-kill=${app_shutdown_kill}ms"
  if [ "$load" = "sequential" ]; then
    echo "requests: $(wc -l < "$o/sequential-codes.txt" | tr -d ' ')"
    echo "502: $(grep -c '^502' "$o/sequential-codes.txt")"
  else
    echo "requests: $(grep -c . "$o/front-access.log")"
    echo "502: $(awk '$2==502' "$o/front-access.log" | wc -l | tr -d ' ')"
    echo "2xx: $(awk '$2==200' "$o/front-access.log" | wc -l | tr -d ' ')"
  fi
  echo "requests the backend received: $(grep -vc '__close-idle' "$o/backend-access.log" 2>/dev/null || echo -)"
  echo "turnovers: $(wc -l < "$o/turnover-times.txt" 2>/dev/null | tr -d ' ' || echo 0)"
  echo "--- front error log ---"
  sed -E 's/^[0-9\/: ]+\[[a-z]+\] [0-9]+#[0-9]+: (\*[0-9]+ )?//; s/,.*//' "$o/front-error.log" 2>/dev/null | sort | uniq -c | sort -rn
  echo "--- nstat ---"
  grep -E 'TcpEstabResets|TCPAbortOnData|TcpOutRsts|TcpActiveOpens|TcpPassiveOpens' "$o/nstat.txt"
} | tee "$o/summary.txt"
