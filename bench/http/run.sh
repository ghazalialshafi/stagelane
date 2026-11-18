#!/bin/sh
# Socket benchmark: HTTP hello server, three traffic shapes, server CPU per request.
#   sh run.sh                 builds everything and runs stagelane (stock / zerocopy / ring) and Go
# needs: nim 2.2+, go (optional), strace (optional, for the syscall table); Linux.
cd "$(dirname "$0")"
SRC=../../src
B=build; mkdir -p $B
nim c -d:release --overflowChecks:off --hints:off --warnings:off --mm:arc -p:$SRC -o:$B/stagelane_http stagelane_http.nim || exit 1
HAVE_GO=0
if command -v go >/dev/null 2>&1; then
  (cd loadgen && go build -o ../$B/loadgen .) && (cd gohttp && go build -o ../$B/gohttp .) && HAVE_GO=1
fi
[ $HAVE_GO = 1 ] || { echo "go is needed for the load generator"; exit 1; }

now_ticks() { awk '{print $14+$15}' /proc/$1/stat; }   # utime+stime in clock ticks (10 ms)
scenario() { # label port pid name loadgen-args...
  label=$1; port=$2; pid=$3; name=$4; shift 4
  t0=$(now_ticks $pid)
  out=$(timeout 15 $B/loadgen -addr 127.0.0.1:$port -conns 64 -secs 3 "$@" | tail -1)
  t1=$(now_ticks $pid)
  reqs=$(echo "$out" | sed -E 's/.*requests=([0-9]+).*/\1/')
  rps=$(echo "$out" | sed -E 's/.*rps=([0-9]+).*/\1/')
  awk -v l="$label" -v n="$name" -v r="$reqs" -v rps="$rps" -v t=$((t1-t0)) \
    'BEGIN{printf "%-28s %-8s rps=%7d  server-cpu=%.2f us/req\n", l, n, rps, (t*10000.0)/r}'
}
run() { # label port command...
  label=$1; port=$2; shift 2
  "$@" > /dev/null 2>&1 &
  pid=$!
  sleep 1
  scenario "$label" $port $pid busy
  scenario "$label" $port $pid idle1ms -gap 1ms
  scenario "$label" $port $pid churn -churn
  kill $pid 2>/dev/null; wait $pid 2>/dev/null
}
echo "busy = keep-alive, back-to-back; idle1ms = keep-alive with 1 ms gaps; churn = one request per connection"
run "stagelane stock API"      8201 $B/stagelane_http 8201 stock
run "stagelane zero-copy"      8202 $B/stagelane_http 8202 zerocopy
run "stagelane io_uring"       8203 $B/stagelane_http 8203 ring
GOMAXPROCS=1 run "go net/http (1 proc)" 8204 $B/gohttp 8204
