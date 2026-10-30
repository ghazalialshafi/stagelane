#!/bin/sh
# usage: tests/run_all.sh [nim-flags...]   -- runs every t_*.nim under arc and orc (+ASAN)
cd "$(dirname "$0")"
fail=0
for mm in arc orc; do
  for f in t_*.nim; do
    case $f in t_leak.nim|t_gen.nim|t_loop1.nim|t_mt.nim) continue;; esac
    out=$(nim c --mm:$mm --hints:off --warningAsError:Deprecated --warningAsError:UnusedImport \
       --passC:-fsanitize=address --passL:-fsanitize=address \
      -d:useMalloc "$@" -r $f 2>&1)
    if echo "$out" | grep -qE "FAIL|Error|AddressSanitizer|Traceback|Warning"; then
      echo "FAIL [$mm] $f"; echo "$out" | tail -15; fail=1
    else echo "pass [$mm] $f"; fi
  done
done
# purity metadata carried by the symbols alone (no compile-time side table)
out=$(nim c -d:flowNoPurityTable --hints:off --warningAsError:Deprecated  -r t_xmod.nim 2>&1)
if echo "$out" | grep -qE "FAIL|Error|AssertionDefect|Warning"; then echo "FAIL [symbol-only purity] t_xmod.nim"; echo "$out" | tail; fail=1
else echo "pass [symbol-only purity] t_xmod.nim"; fi
# every example must keep compiling
for f in ../examples/hello ../examples/pipeline ../examples/use_lib ../examples/echo_server; do
  if nim c --hints:off --warningAsError:Deprecated  $f.nim >/dev/null 2>&1; then echo "pass [example] $f"
  else echo "FAIL [example] $f"; fail=1; fi
done
if nim c --threads:on --mm:atomicArc -d:flowThreads --hints:off --warningAsError:Deprecated  ../examples/offload.nim >/dev/null 2>&1; then echo "pass [example] offload"
else echo "FAIL [example] offload"; fail=1; fi
# every code block in the docs must compile and run
if sh ./docs_check.sh >/dev/null 2>&1; then echo "pass [docs] all code blocks"; else echo "FAIL [docs]"; fail=1; fi
# multi-threaded build
for f in t_mt.nim; do
  out=$(nim c --threads:on --mm:atomicArc -d:flowThreads --hints:off --warningAsError:Deprecated \
     --passC:-fsanitize=address --passL:-fsanitize=address \
    -d:useMalloc -r $f 2>&1 | grep -v "LeakSanitizer\|^    #\|SUMMARY\|^$\|leak of\|Direct leak\|Indirect leak")
  if echo "$out" | grep -qE "FAIL|Error|AddressSanitizer: (heap|stack|use)|Traceback|Assertion|Warning"; then
    echo "FAIL [atomicArc+threads] $f"; echo "$out" | tail; fail=1
  else echo "pass [atomicArc+threads] $f"; fi
done
exit $fail
