#!/bin/sh
# Compile and run every demo, verify it exits 0 (each demo asserts its own result).
#
#   ./run_all.sh              run all 20 demos
#   ./run_all.sh 05 12 19     run only demos whose file starts with d05 / d12 / d19
#   NIM=/path/to/nim ./run_all.sh     use a specific nim binary
#   VERBOSE=1 ./run_all.sh    show each demo's output (default: only on failure)
#
# Demos that import stagelane/exec (the thread pool) are automatically built with
#   --threads:on --mm:atomicArc -d:flowThreads
# everything else uses --mm:arc.  All are built with -d:danger for speed.

cd "$(dirname "$0")" || exit 1
NIM=${NIM:-nim}
SRC=../src
BUILD=${BUILD:-.build}
mkdir -p "$BUILD"

if ! command -v "$NIM" >/dev/null 2>&1 && [ ! -x "$NIM" ]; then
  echo "nim not found. Install Nim 2.2+ or run: NIM=/path/to/nim $0"; exit 2
fi
echo "using $($NIM --version | head -1)"
echo

if [ $# -gt 0 ]; then
  files=""
  for n in "$@"; do files="$files $(ls d${n#d}_*.nim 2>/dev/null)"; done
else
  files=$(ls d[0-9][0-9]_*.nim)
fi

pass=0; fail=0; failed=""
printf "%-34s %-8s %s\n" "DEMO" "RESULT" "TIME"
printf "%-34s %-8s %s\n" "----" "------" "----"
for f in $files; do
  b=${f%.nim}
  if grep -q "stagelane/exec" "$f"; then
    flags="--threads:on --mm:atomicArc -d:flowThreads"
  else
    flags="--mm:arc"
  fi
  log="$BUILD/$b.log"
  if ! $NIM c -d:danger --hints:off --warnings:off --path:$SRC $flags -o:"$BUILD/$b" "$f" >"$log" 2>&1; then
    printf "%-34s %-8s\n" "$b" "COMPILE-FAIL"; fail=$((fail+1)); failed="$failed $b"
    tail -15 "$log"; continue
  fi
  start=$(date +%s%N)
  timeout 120 "$BUILD/$b" >>"$log" 2>&1
  rc=$?
  ms=$(( ($(date +%s%N) - start) / 1000000 ))
  if [ $rc -eq 0 ]; then
    printf "%-34s %-8s %d ms\n" "$b" "PASS" "$ms"; pass=$((pass+1))
    [ -n "$VERBOSE" ] && sed 's/^/    | /' "$log"
  else
    printf "%-34s %-8s (exit %d)\n" "$b" "FAIL" "$rc"; fail=$((fail+1)); failed="$failed $b"
    tail -15 "$log" | sed 's/^/    | /'
  fi
done

echo
echo "passed: $pass   failed: $fail"
[ $fail -eq 0 ] || { echo "failed:$failed"; exit 1; }
