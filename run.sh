#!/usr/bin/env bash
# Reproduces the keepalive reuse race and compares mitigations.
#
#   ./run.sh <scenario>
#
#   baseline-concurrent  64-way concurrency, backend reloaded every 0.4s
#   baseline-sequential  one request at a time, same reloads (control)
#   retry-get            default proxy_next_upstream, GET (retries hide it)
#   retry-post           default proxy_next_upstream, POST (not retried)
#   ka-timeout           keepalive_timeout 5s on front's upstream
#   idle-close           no reload, backend keepalive_timeout 1s
#
# Scenarios with a Node.js backend instead of nginx (it speaks keepalive and
# closes idle connections on its own 5s timer, like most app servers):
#
#   app-baseline         64-way concurrency, the app restarted every 0.4s
#   app-idle-close       no restarts, the app's own keepAliveTimeout closes them
#   app-slow-nonidem     the app spends 50ms processing, POST, non_idempotent.
#                        Stopped with SIGTERM, so in-flight requests finish
#   app-slow-kill        same, but the instance is SIGKILLed mid-processing, so
#                        the response is lost after the work was done. This is
#                        the path where a retry can execute it twice
#
# Everything is kept under out/<scenario>/.
set -uo pipefail
sc="${1:?scenario}"
cd /lab
o="out/$sc"; rm -rf "$o"; mkdir -p "$o" run

front_conf=conf/front-baseline.conf
backend_conf=conf/backend.conf
do_reload=1
load=get
backend_kind=nginx
app_keepalive=""
app_slow=0
app_signal=TERM

case "$sc" in
  baseline-concurrent) ;;
  baseline-sequential) load=sequential ;;
  retry-get)   front_conf=conf/front-retry.conf ;;
  retry-post)  front_conf=conf/front-retry.conf; load=post ;;
  nonidem-post) front_conf=conf/front-nonidem.conf; load=post ;;
  backend-noka) backend_conf=conf/backend-noka.conf ;;
  drain)       do_reload=2 ;;
  app-baseline)     backend_kind=app; front_conf=conf/front-app.conf ;;
  app-idle-close)   backend_kind=app; front_conf=conf/front-app.conf; app_keepalive=1000; do_reload=0; load=bursty ;;
  app-slow-nonidem) backend_kind=app; front_conf=conf/front-app-nonidem.conf; app_slow=50; load=post ;;
  app-slow-kill)    backend_kind=app; front_conf=conf/front-app-nonidem.conf; app_slow=50; load=post; app_signal=KILL ;;
  baseline-20s) ;;
  ka-timeout)  front_conf=conf/front-ka-timeout.conf ;;
  idle-close)  backend_conf=conf/backend-idle.conf; do_reload=0; load=bursty ;;
  *) echo "unknown scenario: $sc"; exit 2 ;;
esac

sed "s|/lab/out/|/lab/$o/|g" "$backend_conf" > "run/backend.conf"
sed "s|/lab/out/|/lab/$o/|g" "$front_conf"   > "run/front.conf"
cp "$front_conf" "$o/"
[ "$backend_kind" = "nginx" ] && cp "$backend_conf" "$o/"

# Two instances, so that retiring one always leaves the other serving. This is
# what a real deploy looks like; restarting a single process would produce
# connection-refused rather than the race under test.
start_app() { # port
  PORT="$1" SLOW_MS="$app_slow" KEEPALIVE_MS="$app_keepalive" LOG="/lab/$o/backend-access.log" \
    node /lab/app/server.js 2>>"$o/backend-error.log" &
  echo $! > "run/app-$1.pid"
}
stop_app() { # port
  [ -f "run/app-$1.pid" ] || return 0
  kill -"$app_signal" "$(cat "run/app-$1.pid")" 2>/dev/null
  wait "$(cat "run/app-$1.pid")" 2>/dev/null
  rm -f "run/app-$1.pid"
}

if [ "$backend_kind" = "app" ]; then
  cp app/server.js "$o/"
  start_app 8081; start_app 8082; sleep 1
else
  nginx -c /lab/run/backend.conf -p /lab & sleep 1
fi
nginx -c /lab/run/front.conf -p /lab & sleep 1

tcpdump -i lo -n -s 128 "tcp port 8081 and (tcp[tcpflags] & (tcp-fin|tcp-rst|tcp-push) != 0)" \
  -w "$o/loopback.pcap" 2>"$o/tcpdump.log" &
tcpdump_pid=$!
sleep 1
nstat -n

if [ "$do_reload" = "2" ]; then
  # drain: take the retiring backend out of front's upstream first (swap the
  # config and reload), then stop it once the old workers are gone
  sed "s|/lab/out/|/lab/$o/|g" conf/backend-b.conf > run/backend-b.conf
  sed "s|/lab/out/|/lab/$o/|g" conf/front-baseline.conf > run/front-to-a.conf
  sed "s|/lab/out/|/lab/$o/|g" conf/front-b.conf        > run/front-to-b.conf
  ( end=$((SECONDS + 60)); cur=a
    while [ $SECONDS -lt $end ]; do
      if [ "$cur" = "a" ]; then
        nginx -c /lab/run/backend-b.conf -p /lab & sleep 0.3
        cp run/front-to-b.conf run/front.conf
        nginx -c /lab/run/front.conf -p /lab -s reload 2>>"$o/reload.log"
        sleep 0.7
        nginx -c /lab/run/backend.conf -p /lab -s quit 2>>"$o/reload.log"
        cur=b
      else
        nginx -c /lab/run/backend.conf -p /lab & sleep 0.3
        cp run/front-to-a.conf run/front.conf
        nginx -c /lab/run/front.conf -p /lab -s reload 2>>"$o/reload.log"
        sleep 0.7
        nginx -c /lab/run/backend-b.conf -p /lab -s quit 2>>"$o/reload.log"
        cur=a
      fi
      date +%s.%N >> "$o/reload-times.txt"
    done ) &
  reload_pid=$!
elif [ "$do_reload" = "1" ] && [ "$backend_kind" = "app" ]; then
  # A deploy replaces one instance at a time, the other keeps serving
  ( end=$((SECONDS + 60)); port=8081
    while [ $SECONDS -lt $end ]; do
      stop_app "$port"; start_app "$port"
      date +%s.%N >> "$o/reload-times.txt"
      [ "$port" = "8081" ] && port=8082 || port=8081
      sleep 0.4
    done ) &
  reload_pid=$!
elif [ "$do_reload" = "1" ]; then
  ( end=$((SECONDS + 60))
    while [ $SECONDS -lt $end ]; do
      nginx -c /lab/run/backend.conf -p /lab -s reload 2>>"$o/reload.log"
      date +%s.%N >> "$o/reload-times.txt"
      sleep 0.4
    done ) &
  reload_pid=$!
else
  reload_pid=""
fi

case "$load" in
  get)  if [ "$sc" = "baseline-20s" ] || [ "$sc" = "drain" ]; then
          ab -r -k -c 64 -t 20 -n 5000000 -s 30 http://127.0.0.1:8080/ > "$o/ab.log" 2>&1
        else
          ab -r -k -c 64 -n 70000 -s 30 http://127.0.0.1:8080/ > "$o/ab.log" 2>&1
        fi ;;
  post) printf 'x=1' > run/post.txt
        ab -r -k -c 64 -n 70000 -s 30 -p run/post.txt -T application/x-www-form-urlencoded \
           http://127.0.0.1:8080/ > "$o/ab.log" 2>&1 ;;
  sequential)
        for i in $(seq 1 400); do
          curl -s -o /dev/null -w '%{http_code}\n' http://127.0.0.1:8080/ >> "$o/sequential-codes.txt"
          sleep 0.15
        done ;;
  bursty)
        # no reload. Bursts of load with gaps, letting the backend's 1s idle timeout close connections
        for round in $(seq 1 20); do
          ab -r -k -c 64 -n 2000 -s 30 http://127.0.0.1:8080/ >> "$o/ab.log" 2>&1
          sleep 1.5
        done ;;
esac

[ -n "$reload_pid" ] && { kill $reload_pid 2>/dev/null; wait $reload_pid 2>/dev/null; }
nstat > "$o/nstat.txt"
sleep 1
kill $tcpdump_pid 2>/dev/null; wait $tcpdump_pid 2>/dev/null
nginx -c /lab/run/front.conf -p /lab -s quit 2>/dev/null
if [ "$backend_kind" = "app" ]; then stop_app 8081; stop_app 8082; else nginx -c /lab/run/backend.conf -p /lab -s quit 2>/dev/null; fi
sleep 1

{
  echo "scenario: $sc"
  echo "front: $front_conf / backend: $backend_kind ${backend_conf} keepalive=${app_keepalive:-default} slow=${app_slow}ms signal=${app_signal} / reload: $do_reload / load: $load"
  if [ "$load" = "sequential" ]; then
    echo "requests: $(wc -l < "$o/sequential-codes.txt")"
    echo "502: $(grep -c '^502' "$o/sequential-codes.txt")"
  else
    echo "requests: $(grep -c . "$o/front-access.log")"
    echo "502: $(awk '$2==502' "$o/front-access.log" | wc -l | tr -d ' ')"
    echo "2xx: $(awk '$2==200' "$o/front-access.log" | wc -l | tr -d ' ')"
  fi
  echo "--- front error log ---"
  sed -E 's/^[0-9\/: ]+\[error\] [0-9]+#[0-9]+: \*[0-9]+ //; s/, client:.*//' "$o/front-error.log" 2>/dev/null | sort | uniq -c | sort -rn
  echo "requests the backend received: $(grep -c . "$o/backend-access.log" 2>/dev/null || echo -)"
  echo "--- nstat ---"
  grep -E 'TcpEstabResets|TCPAbortOnData|TcpOutRsts|TcpActiveOpens|TcpPassiveOpens' "$o/nstat.txt"
} | tee "$o/summary.txt"
