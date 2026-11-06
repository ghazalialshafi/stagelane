# Why stagelane

## The problem

A program that talks to the network, files or timers spends most of its life
*waiting*. You have three classic ways to deal with it:

1. **One thread per job.** Simple, but threads are heavy (stacks, scheduling), and a
   few thousand connections is already a problem.
2. **Callbacks.** Cheap, but your logic gets chopped into pieces; loops, `try/finally`
   and error handling turn into puzzles.
3. **async/await.** Straight-line code again, but every call in the chain must be
   awaited and every proc that awaits becomes a different kind of proc.

stagelane is a fourth way: write straight-line code, mark the proc that may wait, and
let the compiler cut it into resumable pieces.

## What it does

`{.flow.}` type-checks your proc normally, then rewrites it into small stages that
share a heap *frame* holding the locals that must survive a pause. A pause is just
"store the frame somewhere, run something else". Resuming is "run the next stage".
Code between pauses is your original Nim, untouched, so loops, `case`, `try/finally`,
`defer`, `break`, closures and the whole standard library keep working.

## The colour problem

In async/await languages, functions come in two colours. An async function can only
be awaited from another async function, so one `await` at the bottom infects every
caller above it, and you cannot call it from plain code without ceremony.

What stagelane changes:

| | async/await | stagelane |
|---|---|---|
| calling a pausing proc | `await f()` at every call site | `f()` like any call |
| calling it from plain code | needs an event loop dance (`waitFor`) | just call it |
| a proc that never pauses | still a `Future`, still allocates | compiled to a plain native proc |
| working out if a call can pause | read the signature | `neverSuspends(f(x))` at compile time |

```nim
import stagelane

proc price(sku: string): int {.flow.} =
  delay(5)                        # pretend network call
  sku.len * 100

proc withTax(c: int): int {.flow.} = c * 12 div 10     # never pauses: plain native code

proc total(skus: seq[string]): int {.flow.} =
  for s in skus: result += withTax(price(s))           # no await anywhere

static: doAssert neverSuspends(withTax(1))
echo total(@["apple", "fig"])      # called from ordinary code: just works
```

**What is honest to say:** the *declaration* is still marked (`{.flow.}`), so this is
not magic colourlessness. What disappears is the marker at every call site, the
"you must be inside an async proc" restriction, and the cost of procs that do not
pause. Today a flow proc cannot be stored in a `proc` variable or be generic;
those are on the list.

## How it compares

`std/asyncdispatch`, same machine, `-d:danger --mm:arc`, median of several runs
(`bench/bench.nim`, `bench/vs_async.nim`):

| | asyncdispatch | stagelane |
|---|---|---|
| call of a proc that pauses (loop) | 100 ns | **~10-15 ns** |
| spawn a task and await it (it pauses once) | 430 ns | **~130 ns** |
| switch between tasks | n/a | **~14 ns** |
| channel message between tasks | n/a (`FutureStream` only) | **~31 ns** |
| proc that never pauses | allocates a future | **native call, 0 allocations** |
| CPU loop inside a pausing proc | closure-iterator state machine | **plain C loop (0.4 ns/iter)** |

Features:

| | asyncdispatch | stagelane |
|---|---|---|
| structured concurrency | no | `scope` (children cannot leak, first error cancels siblings) |
| cancellation | no | yes, everywhere a task can be parked |
| timeouts | `withTimeout` on futures | `withTimeout`, `waitFor`, `select` timeout arm |
| channels / select / mutex / semaphore | `FutureStream` only | yes |
| threads | one loop per thread, manual | `Pool`, tasks awaitable across threads |
| memory model | works under ARC, not benchmarked here under sanitizers | ARC/ORC, test suite ASAN/TSAN clean |

(Numbers move +-30% between runs on shared hardware; the ratios are stable.
Benchmarks are in `bench/`.)

### Against Nimony `.passive` and Go

`bench/compare/` runs the same nine workloads on stagelane, Nimony's `.passive`
continuations and Go goroutines (`python3 run_bench.py`; needs `nim`, `nimony`, `go`).
Latest run, **1 shared vCPU**, median of 5, ns/op (lower is better; `cpu` and `timers`
are total milliseconds), with the thread pools at 4 workers in the multi section:

| benchmark | stagelane | nimony .passive | go |
|---|---|---|---|
| call_10M (a call that can pause) | **9.9** | 16.8 | 1.5 (plain call, not comparable) |
| yield_2M | **11.9** | 90.1 | 108.3 |
| spawn_200k | **16.8** | 69.0 | 701.4 |
| fanout_100k_x3yield | **21.0** | 47.5 | 471.0 |
| pingpong_200k | **51.7** | 460.0 | 193.5 |
| timers_100k | **27 ms** | 43 ms | 191 ms |
| cpu_64x2M | 106 ms | 110 ms | **91 ms** |
| chan_pipe_20000 | **21.9** | HANG | 67.8 |
| chan_pipe_500000 | **39.0** | HANG | 47.9 |
| multi: spawn_200k, `pool.go` + await | 239.3 | **69.2** | 469.2 |
| multi: spawn_200k, `pool.spawn` + `Latch` | 84.0 | **69.8** | 495.1 |

How to read this, honestly:

* **Nimony's spawn is fire-and-forget; `pool.go` returns a handle.** Handle-based
  `pool.go` pays for a result slot and completion state, so Nimony is ahead in the
  multi-worker spawn row (about 3.5x for `pool.go`, about 1.2x for the like-for-like
  `pool.spawn`). That is the one row stagelane loses besides the two below.
* **cpu_64x2M measures the C compiler, not the runtime.** The loop is a plain loop in
  every language; plain Nim and stagelane compile it to the same time. Nimony and Go
  wrap on integer overflow, so the Nim build here uses `--overflowChecks:off` to do the
  same (about 14% on this loop). Go still wins by a few percent.
* **`call_10M`:** Go's number is an ordinary function call, which cannot pause, so it is
  shown for scale only.
* **One CPU.** Multi-worker rows share a single core, so they show scheduling overhead,
  not parallel speed-up, and the single-thread rows are the cleanest comparison.
  Nimony's channel benchmarks hang at 20k / 500k messages in some configurations.
* Absolute numbers depend on the machine (this was a small cloud VM); the ordering is
  what repeated across runs.

## Three things that tend to surprise people

**1. A flow proc is an ordinary proc.** Libraries can export them with `*`; callers
need no special runtime setup. A flow proc that pauses, called from plain code,
drives the event loop itself until it is done.

**2. The standard library needs no wrappers.** Only calls to other flow procs (and
`delay`, `await`, `recv`, ...) are pause points. Everything else is copied through, so
`parseJson`, `sort(proc ...)`, tables, `strutils`, `sqrt` run at full speed, even in
the middle of a pausing proc.

**3. Blocking code can be offloaded without an async rewrite.** Wrap a blocking call
in a one-line flow proc and run it on the pool:

```nim threads
import stagelane, stagelane/exec
import std/os

proc slowQuery(ms: int): string =          # plain blocking code
  os.sleep(ms)
  "rows"

proc query(ms: int): string {.flow.} = slowQuery(ms)

proc main() {.flow.} =
  let pool = newPool(3)
  let a = pool.go query(100)               # three blocking calls run in parallel,
  let b = pool.go query(100)               # the event loop on this thread stays free
  let c = pool.go query(100)
  echo await(a), await(b), await(c)
  pool.shutdown()

run main()
```
(Build with `--threads:on --mm:atomicArc -d:flowThreads`.)

## What it is good for

* Network servers and clients: thousands of connections, one thread.
* Pipelines: stages connected by channels with back-pressure.
* Anything that waits on many things at once: scrapers, schedulers, bots, supervisors.
* Tests that need controllable concurrency and timeouts.
* Mixing in blocking libraries (databases, file formats) via the pool.

## What it is not for

* Pure number crunching on many cores: use plain threads or `Pool` for coarse jobs.
  stagelane helps with *waiting*, not with arithmetic.
* Hard real-time: tasks are cooperative; a task that never pauses starves others
  (call `checkpoint()` or `yieldNow()` in long loops).
