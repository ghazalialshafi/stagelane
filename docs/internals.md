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
  freelist; the next call reuses them.

## Scheduler (`sched.nim`)

Per-thread: an intrusive ready list, a 4-level hashed **timing wheel** (1 ms, O(1)),
an epoll selector, and (threads) a mailbox plus wake-up event so other threads can hand
over frames. A pause primitive is a *hook* `proc (f: Frame, ...): Hop` called straight
from the stage with the caller itself as the frame to park; it returns `noStep` after
parking it, or a hop to continue. `delay`, `yieldNow`, `park`, fd waits and `select`
are all built from this.

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
code block in these docs.
