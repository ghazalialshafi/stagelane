#!/bin/sh
# Compiles and runs every ```nim block in README.md and docs/*.md
# (```nim threads blocks get the multi-threaded flags).
cd "$(dirname "$0")/.."
out=/tmp/stagelane_docs_check; rm -rf $out; mkdir -p $out
python3 - <<'PY'
import re, glob
n = 0
for f in ["README.md"] + sorted(glob.glob("docs/*.md")):
    for m in re.finditer(r"```nim( threads)?\n(.*?)```", open(f).read(), re.S):
        n += 1
        name = re.sub(r"\W", "_", f) + "_%02d" % n
        open("/tmp/stagelane_docs_check/%s%s.nim" % (name, "_threads" if m.group(1) else ""), "w").write(m.group(2))
PY
fail=0
for f in $out/*.nim; do
  flags=""
  case $f in *_threads.nim) flags="--threads:on --mm:atomicArc -d:flowThreads";; esac
  if timeout 60 nim c --path:src $flags --hints:off --warningAsError:Deprecated  \
       -d:danger -r -o:${f%.nim} $f >$f.log 2>&1 && ! grep -q "Warning" $f.log; then echo "pass $(basename $f)"
  else echo "FAIL $(basename $f)"; tail -8 $f.log; fail=1; fi
done
exit $fail
