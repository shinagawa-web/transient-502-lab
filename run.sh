#!/usr/bin/env bash
# keepalive 再利用 race の再現とシナリオ比較。
#
#   ./run.sh <scenario>
#
#   baseline-concurrent  64並行 + backend を0.4秒ごとに reload（素の再現）
#   baseline-sequential  1本ずつ + 同じ reload（対照。条件が欠けると出ない）
#   retry-get            proxy_next_upstream 既定 + GET 負荷（再送で隠れるか）
#   retry-post           proxy_next_upstream 既定 + POST 負荷（非冪等は再送されないか）
#   ka-timeout           front の upstream に keepalive_timeout 5s（reload 起因に効くか）
#   idle-close           reload なし・backend の keepalive_timeout 1s（デプロイ以外でも出るか）
#
# ログは out/<scenario>/ に全部残す。
set -uo pipefail
sc="${1:?scenario}"
cd /lab
o="out/$sc"; rm -rf "$o"; mkdir -p "$o" run

front_conf=conf/front-baseline.conf
backend_conf=conf/backend.conf
do_reload=1
load=get

case "$sc" in
  baseline-concurrent) ;;
  baseline-sequential) load=sequential ;;
  retry-get)   front_conf=conf/front-retry.conf ;;
  retry-post)  front_conf=conf/front-retry.conf; load=post ;;
  nonidem-post) front_conf=conf/front-nonidem.conf; load=post ;;
  backend-noka) backend_conf=conf/backend-noka.conf ;;
  drain)       do_reload=2 ;;
  baseline-20s) ;;
  ka-timeout)  front_conf=conf/front-ka-timeout.conf ;;
  idle-close)  backend_conf=conf/backend-idle.conf; do_reload=0; load=bursty ;;
  *) echo "unknown scenario: $sc"; exit 2 ;;
esac

sed "s|/lab/out/|/lab/$o/|g" "$backend_conf" > "run/backend.conf"
sed "s|/lab/out/|/lab/$o/|g" "$front_conf"   > "run/front.conf"
cp "$front_conf" "$backend_conf" "$o/"

nginx -c /lab/run/backend.conf -p /lab & sleep 1
nginx -c /lab/run/front.conf   -p /lab & sleep 1

tcpdump -i lo -n -s 128 "tcp port 8081 and (tcp[tcpflags] & (tcp-fin|tcp-rst|tcp-push) != 0)" \
  -w "$o/loopback.pcap" 2>"$o/tcpdump.log" &
tcpdump_pid=$!
sleep 1
nstat -n

if [ "$do_reload" = "2" ]; then
  # drain: 退役させる backend を先に front の upstream から外し（front の設定を差し替えて reload）、
  # 旧 worker が消えてからプロセスを落とす
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
        # reload はかけない。負荷を出しては止め、backend の idle timeout(1s) に接続を閉じさせる
        for round in $(seq 1 20); do
          ab -r -k -c 64 -n 2000 -s 30 http://127.0.0.1:8080/ >> "$o/ab.log" 2>&1
          sleep 1.5
        done ;;
esac

[ -n "$reload_pid" ] && { kill $reload_pid 2>/dev/null; wait $reload_pid 2>/dev/null; }
nstat > "$o/nstat.txt"
sleep 1
kill $tcpdump_pid 2>/dev/null; wait $tcpdump_pid 2>/dev/null
nginx -c /lab/run/front.conf   -p /lab -s quit 2>/dev/null
nginx -c /lab/run/backend.conf -p /lab -s quit 2>/dev/null
sleep 1

{
  echo "scenario: $sc"
  echo "front conf: $front_conf / backend conf: $backend_conf / reload: $do_reload / load: $load"
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
  echo "backend が受けた回数: $(grep -c . "$o/backend-access.log" 2>/dev/null || echo -)"
  echo "--- nstat ---"
  grep -E 'TcpEstabResets|TCPAbortOnData|TcpOutRsts|TcpActiveOpens|TcpPassiveOpens' "$o/nstat.txt"
} | tee "$o/summary.txt"
