#!/usr/bin/env python3
"""Concurrency benchmark suite: stagelane vs Nimony .passive vs Go goroutines.

Usage: python3 run_bench.py [--reps 5] [--workers N] [--timeout 30] [--only a,b] [--skip nimony,go]
Env:   NIM_BIN      directory with `nim`          (default: nim from PATH)
       NIMONY_BIN   directory with `nimony`       (default: nimony from PATH)
       STAGELANE_SRC  the repo's src directory     (default: ../../src)
Modes: single = 1 loop / 1 thread / GOMAXPROCS=1 ;  multi = N workers (--workers, default 4)

Build flags: stagelane is built with `-d:release --overflowChecks:off`.  Nimony's
release mode and Go both wrap on integer overflow instead of trapping; the flag makes
the Nim build do the same so the pure-compute row compares codegen, not checking.
Needs only python3 (no GNU `timeout`), so it also runs on macOS.
"""
import argparse, os, signal, subprocess, statistics, shutil, glob, csv, json
H = os.path.dirname(os.path.abspath(__file__)); B = os.path.join(H, "build")
ap = argparse.ArgumentParser()
ap.add_argument("--reps", type=int, default=5); ap.add_argument("--workers", type=int, default=4)
ap.add_argument("--timeout", type=int, default=30); ap.add_argument("--only", default="")
ap.add_argument("--render-only", action="store_true", help="rebuild results.md from results.json (no build, no run)")
ap.add_argument("--skip", default="", help="comma list of runtimes to skip: stagelane,nimony,go")
a = ap.parse_args()
def tool(env, exe):
    d = os.environ.get(env)
    return os.path.join(d, exe) if d else (shutil.which(exe) or exe)
NIM = tool("NIM_BIN", "nim"); NIMONY = tool("NIMONY_BIN", "nimony")
SL = os.environ.get("STAGELANE_SRC", os.path.join(H, "..", "..", "src"))
os.makedirs(B, exist_ok=True)
def sh(cmd, cwd=None, env=None, timeout=None):
    """run through the shell; on timeout kill the whole process group (a hung
    benchmark must not keep burning CPU and distort the runs after it)"""
    e = dict(os.environ, **(env or {}))
    p = subprocess.Popen(cmd, shell=True, cwd=cwd, env=e, stdout=subprocess.PIPE,
                         stderr=subprocess.PIPE, text=True, start_new_session=True)
    try:
        out, err = p.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        os.killpg(p.pid, signal.SIGKILL); p.communicate()
        raise
    return subprocess.CompletedProcess(cmd, p.returncode, out, err)
def render(rows, reps, workers):
    out = [f"# Results ({os.cpu_count()} CPUs, multi workers={workers}, median of {a.reps})\n",
           "ns/op (lower is better); cpu and timers are total ms; HANG = no result within the timeout\n"]
    for mode in ("single", "multi"):
        rs = [r for r in rows if r["mode"] == mode]
        if not rs: continue
        out.append(f"\n## {mode}\n\n| benchmark | stagelane | nimony .passive | go | best |\n|---|---|---|---|---|")
        for b in dict.fromkeys(r["bench"] for r in rs):
            cells = []; vals = {}
            for rt in ("stagelane", "nimony", "go"):
                m = [r for r in rs if r["bench"] == b and r["runtime"] == rt]
                if not m: cells.append("-")
                elif m[0]["us"] is None: cells.append("HANG")
                elif b in ("cpu", "timers"): cells.append(f"{m[0]['us']/1000:.0f} ms"); vals[rt] = m[0]["us"]
                else: cells.append(f"{m[0]['us']*1000/m[0]['ops']:.1f}"); vals[rt] = m[0]["us"]*1000/m[0]["ops"]
            best = min(vals, key=vals.get) if vals else "-"
            if b == "call": best += " (go: plain call, not comparable)"
            names = [r["name"] for r in rs if r["bench"] == b and r["runtime"] == "stagelane"] or \
                    [r["name"] for r in rs if r["bench"] == b]
            label = names[0] + (" (nimony/go: their fire-and-forget spawn)" if b == "spawnd" else "")
            out.append(f"| {label} | " + " | ".join(cells) + f" | {best} |")
    open(f"{H}/results.md", "w").write("\n".join(out)); print("\n".join(out))
if a.render_only:
    d = json.load(open(f"{H}/results.json")); render(d["rows"], a.reps, d["workers"]); raise SystemExit(0)
skip = set(a.skip.split(","))
# ---- build
if "stagelane" not in skip:
    f = f"-d:release --overflowChecks:off --hints:off --warnings:off -p:{SL}"
    r = sh(f"{NIM} c {f} --mm:arc -o:{B}/sl_st {H}/bench_stagelane.nim"); print(r.stderr[-400:] if r.returncode else "built stagelane (single)")
    r = sh(f"{NIM} c {f} --mm:atomicArc --threads:on -d:flowThreads -o:{B}/sl_mt {H}/bench_stagelane.nim"); print(r.stderr[-400:] if r.returncode else "built stagelane (threads)")
if "nimony" not in skip and (os.path.isabs(NIMONY) and os.path.exists(NIMONY) or shutil.which(NIMONY)):
    env = {"PATH": os.path.dirname(NIMONY) + os.pathsep + os.environ["PATH"]} if os.path.isabs(NIMONY) else None
    r = sh(f"{NIMONY} c -d:release bench_nimony.nim", cwd=H, env=env)
    exe = glob.glob(f"{H}/nimcache/c/*/bench_nimony")
    if exe: shutil.copy(exe[0], f"{B}/ny"); print("built nimony")
    else: print(r.stdout[-400:], r.stderr[-400:])
if "go" not in skip and shutil.which("go"):
    r = sh(f"go build -o {B}/gobin .", cwd=f"{H}/go"); print(r.stderr[-300:] if r.returncode else "built go")
BENCH = ["call","yield","spawn","spawnd","fanout","pingpong","timers","cpu","pipe"]
if a.only: BENCH = a.only.split(",")
def run(cmd, env=None):
    try: r = sh(cmd, env=env, timeout=a.timeout)
    except subprocess.TimeoutExpired: return None
    for l in r.stdout.splitlines():
        if l.startswith("RESULT"):
            p = l.split("\t"); return p[2], int(p[3]), int(p[4])
    return None
def cmds(mode, bench, pn):
    W = 1 if mode == "single" else a.workers
    other = "spawn" if bench == "spawnd" else bench   # Nimony/Go spawn is fire-and-forget
    c = {}
    if bench == "spawnd" and mode == "single": return c
    if os.path.exists(f"{B}/gobin"): c["go"] = (f"{B}/gobin {other} {pn}", {"GOMAXPROCS": str(W)})
    if os.path.exists(f"{B}/ny"):    c["nimony"] = (f"{B}/ny {W} {other} {pn}", None)
    if os.path.exists(f"{B}/sl_st"):
        # stagelane: one event loop per thread; spawn/spawnd/cpu use a Pool in multi mode
        if mode == "multi" and bench in ("spawn","spawnd","cpu") and os.path.exists(f"{B}/sl_mt"):
            c["stagelane"] = (f"{B}/sl_mt {W} {bench} {pn}", None)
        else: c["stagelane"] = (f"{B}/sl_st 0 {bench} {pn}", None)
    return c
rows = []
for mode in ("single", "multi"):
    if mode == "multi" and a.workers == 1: continue
    for bench in BENCH:
        for rt, (cmd, env) in cmds(mode, bench, 20000).items():
            if rt in skip: continue
            ts = []; name = None; ops = 0
            for _ in range(a.reps):
                r = run(cmd, env)
                if r is None: ts = None; break
                name, ops, us = r; ts.append(us)
            if ts is None:
                name = bench; ops = 0
            rows.append(dict(mode=mode, bench=bench, name=name, runtime=rt, ops=ops,
                             us=(statistics.median(ts) if ts else None)))
            print(mode, rt, bench, rows[-1]["us"] if ts else "HANG/TIMEOUT", flush=True)
# extra probe: big pipe (500k) exposes channel hangs
for mode in ("single", "multi"):
    if mode == "multi" and a.workers == 1: continue
    if a.only and "pipe" not in a.only: continue
    for rt, (cmd, env) in cmds(mode, "pipe", 500000).items():
        if rt in skip: continue
        r = run(cmd, env)
        rows.append(dict(mode=mode, bench="pipe500k", name="chan_pipe_500000", runtime=rt, ops=500000 if r else 0, us=r[2] if r else None))
        print(mode, rt, "pipe500k", r[2] if r else "HANG/TIMEOUT", flush=True)
json.dump(dict(cpus=os.cpu_count(), workers=a.workers, rows=rows), open(f"{H}/results.json", "w"), indent=1)
with open(f"{H}/results.csv", "w") as f:
    w = csv.writer(f); w.writerow(["mode","bench","runtime","ops","us","ns_per_op"])
    for r in rows: w.writerow([r["mode"], r["name"], r["runtime"], r["ops"], r["us"], (r["us"]*1000/r["ops"]) if r["us"] and r["ops"] else ""])
render(rows, a.reps, a.workers)
