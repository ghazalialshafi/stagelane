# Internals

For contributors and the curious. You never need this to use stagelane.

## The idea

`{.flow.}` turns a proc into a state machine whose state lives in a heap object.

```nim skip
proc f(x: int): int {.flow.} =
  let a = g(x)        # g can pause
  delay(5)
  a + 1
```

becomes, roughly: a *frame* type holding `x`, `a`, the result slot and the next stage;
three *stages* (`start`, `after g`, `after delay`), each a `proc (env: pointer): Hop`.
A `Hop` is "run this stage on this frame next", returned in two registers.
`drive` is a loop: `while hop.stage != nil: hop = hop.stage(hop.env)`.

## Pipeline

1. `{.flow.}` (macro, untyped) emits a *stub* with your signature, a forward declared
   constructor and direct proc, and passes a copy of your proc, renamed, to
2. `flowTransform` (macro, **typed**): the body is already type-checked. It
   * decides purity (can this ever reach a pause point?). Pure procs get their real
     body in the direct proc and callers call it natively;
   * lowers control flow to stages (`transform.nim`: `lower*`), hoisting pause points
     out of expressions (`flat`) with evaluation order kept;
   * rewrites everything else with `rb`: a typed-to-untyped rebuild that strips hidden
     conversions and renames locals, so Nim re-checks it normally;
   * moves locals that cross a stage boundary into the frame, then demotes the ones
     that never do back to stack variables (`demoteFields`).

## Memory

* One owner per live frame, a raw **pin** that moves between the running stage and
  the ready queue / wait queues / timer wheel / fd table. Moving it is free; stages
  *borrow* the frame (`{.cursor.}`), so there is no refcounting on hot paths.
* `finish` releases the pin: the frame and its fields are destroyed. Dropping a parked
  chain (a queue destroyed with waiters) releases each pin up to the root.
* `caller` is a raw pointer to a frame that is itself pinned while its callee runs;
  results go straight into the caller's `dest` slot. No cycles, nothing for ORC to trace.
* Finished frames (default base type) are reset and parked on a per-proc thread-local
  freelist; the next call reuses them. The hot call/return path is written to avoid
  work the compiler cannot elide: the child frame is adopted as a pin straight away
  (`pin` is `nodestroy`, no owned local, no cleanup frame), the pooled frame is adopted
  with a `copyMem` instead of a copy-then-destroy, plain fields are cleared with an
  assignment and plain results are read, not `move`d (`flowTake`/`flowClear`), and
  `ex` is only reset when set. A `for` loop's step stage is started *after* its body so
  the jumps into it are direct calls (a stage is entered directly only by a jump to a
  higher id); only the back edge to the head is a driver hop.

## Scheduler (`sched.nim`)

Per-thread: an intrusive ready list, a 4-level hashed **timing wheel** (1 ms, O(1)),
an epoll selector, and (threads) a mailbox plus wake-up event so other threads can hand
over frames. The mailbox is a lock-free intrusive MPSC queue (Vyukov) threaded through
`Frame.next`: a poster does one exchange and one release store, the owner pops without a
lock. The wake-up syscall is only made when the owner has published `sleeping` (it sets
the flag, looks at the mailbox one last time, then blocks), and an idle thread first
yields the CPU a few times before it sleeps: a consumer that blocks the instant it runs
dry turns every post into two context switches. A task's completion state and its
(lazily created) wait queue are guarded by one of 64 global stripe locks instead of a
per-task queue + mutex. Pool teardown frees a worker's mailbox only after the thread has
been joined. A pause primitive is a *hook* `proc (f: Frame, ...): Hop` called straight
from the stage with the caller itself as the frame to park; it returns `noStep` after
parking it, or a hop to continue. `delay`, `yieldNow`, `park`, fd waits and `select`
are all built from this.

`go` of a proc that cannot pause runs it inline (`goInline`) and returns a finished
task; `scope` forgets successful children (`prune`, amortised, never while `join` walks
the list) and `go(scope, ...)` ends in `spawnPoint()`, an `inlineSuspend` primitive whose
hook continues at once unless the ready queue has reached `spawnHighWater`.
`Pool.spawn` posts a frame whose `caller` is nil: nothing is allocated for a result.

Cancellation: a task records what it is parked on; `cancel` unlinks it from there,
stores `CancelledError` in the frame and reschedules it; its next stage re-raises.

## Exceptions

A raise inside a stage lands in `drive`, which frees that frame and delivers the
exception to its `caller`; the caller's next stage re-raises it inside its own
`try` region. Regions are tracked per stage; `finally` uses a pending-action
selector so `break`/`continue`/`return` run it.

## Tests

`tests/run_all.sh` builds every test under ARC, ORC and atomicArc+threads with
AddressSanitizer, checks purity metadata with and without the compile-time table
(`-d:flowNoPurityTable`), compiles the examples. `tests/docs_check.sh` runs every
code block in these docs. `t_fast.nim` pins the behaviour of the fast paths (inline `go`,
scope pruning, spawn point, loop-step fusion, pooled-frame hygiene); `t_fastmt.nim`
covers the lock-free mailbox, `spawn`, `Latch`, cross-thread await/cancel and pool churn.
The threaded tests are also expected to be clean under ThreadSanitizer
(`--passC:-fsanitize=thread --passL:-fsanitize=thread -d:useMalloc`).

`bench/compare/` is the three-way benchmark against Nimony and Go (`python3 run_bench.py`).
