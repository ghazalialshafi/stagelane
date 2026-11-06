# Three-way benchmark: stagelane vs Nimony `.passive` vs Go

Nine workloads, identical shape in all three languages:

| name | what it measures |
|---|---|
| `call` | 10M calls of a proc that *can* pause (but doesn't) |
| `yield` | 2M task switches |
| `spawn` | 200k tasks started and awaited (stagelane: local `go`; in `multi`, `pool.go`) |
| `spawnd` | multi only: stagelane's fire-and-forget `pool.spawn` + `Latch` (compare with Nimony/Go's spawn, which is also fire-and-forget) |
| `fanout` | 100k tasks that each yield 3 times |
| `pingpong` | 200k channel round trips |
| `timers` | 100k sleepers (wall-clock bound) |
| `cpu` | 64 x 2M-iteration compute loop |
| `pipe` | channel pipeline, 20k and 500k messages |

## Run

```
python3 run_bench.py                    # single + multi(4), median of 5
python3 run_bench.py --only spawn,fanout --reps 9
python3 run_bench.py --skip nimony      # no Nimony installed
python3 run_bench.py --render-only      # rebuild results.md from results.json
```

`nim` (2.2+), `nimony` and `go` are taken from `PATH`, or from `NIM_BIN` / `NIMONY_BIN`
(directories). `STAGELANE_SRC` defaults to this repo's `src`. Only python3 is needed
for the harness itself (works on Linux and macOS); a hung benchmark is killed after
`--timeout` seconds together with its children.

## Methodology notes

* stagelane is built `-d:release --overflowChecks:off`: Nimony's release mode and Go wrap
  on integer overflow, so the Nim build does too. Without it the pure-compute row is about
  14% slower for reasons that have nothing to do with the runtime.
* Pool start-up and shutdown are outside the timed region for stagelane, as they are for
  Nimony (`initPool` before the clock, `shutdownPool` after).
* Nimony's `submit` is fire-and-forget, `pool.go` returns a handle: `spawnd` is the
  like-for-like row for stagelane, `spawn` the like-for-like row for code that needs results.
* Results depend heavily on the machine and on page-fault cost (a 200k-task spawn touches
  tens of MB). Compare ratios within one run, not absolute numbers across machines.

`results.md` is the output of the latest run (1 shared vCPU).
