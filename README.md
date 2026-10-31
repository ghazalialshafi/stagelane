# stagelane

Concurrency for Nim that reads like ordinary code.

Mark a proc `{.flow.}` and it may *pause*: wait for a timer, a socket, a channel,
another task. While it waits, nothing is blocked and no thread is used. Run thousands
of them on one event loop, or spread them over a thread pool.

```nim
import stagelane

proc fetch(name: string, ms: int): string {.flow.} =
  delay(ms)                          # pauses this proc, not the thread
  "hello from " & name

proc main() {.flow.} =
  scope s:                           # leaves only when every child is done
    for i in 0..2:
      discard s.go fetch("task" & $i, 10 * i)
  echo "all done"

run main()
```

## Why you might want it

* **No `await` on every call.** Call a flow proc like any proc. Only the proc
  declaration is marked. [More](docs/why.md#the-colour-problem).
* **Fast.** A pausing call costs ~22 ns, a task switch ~16 ns, spawn + await ~160 ns:
  3-4x faster than `std/asyncdispatch`, and procs that never pause compile to plain
  native code. [Numbers](docs/why.md#how-it-compares).
* **Structured.** `scope` guarantees no task outlives its block; the first failure
  cancels the siblings; cancellation reaches tasks wherever they are parked.
* **Everything included.** Tasks, timers, timeouts, channels, `select`, mutexes,
  semaphores, TCP, and a thread pool for multi-core and for offloading blocking code.
* **Your code stays your code.** The whole standard library works inside flow procs,
  and a flow proc is also an ordinary proc you can call from anywhere.
* **Safe under ARC and ORC**, checked with AddressSanitizer and ThreadSanitizer.

## Where to go next

| | |
|---|---|
| [docs/guide.md](docs/guide.md) | learn it step by step (30 minutes) |
| [docs/why.md](docs/why.md) | what problem it solves, colour problem, comparison with asyncdispatch |
| [docs/recipes.md](docs/recipes.md) | worker pools, retries, rate limits, graceful shutdown |
| [docs/internals.md](docs/internals.md) | how it works, if you are curious or contributing |
| `examples/` | runnable programs: echo server, pipeline, thread-pool offload, a library |
| [demos](demos/) | contains 20 demo program to showcase the power of stagelane |

## Status

Version 0.1. Solid core, tested under sanitizers on Linux. Known gaps: no generic
flow procs yet, sockets are POSIX-only. See [limits](docs/guide.md#limits).
