# Guide

Ten short steps. Every program here is compiled and run by `tests/docs_check.sh`, so
what you read works. Compile with `nim c -d:danger -r file.nim` (add
`--path:/path/to/stagelane/src` if stagelane is not installed).

## 1. Your first flow

```nim
import stagelane

proc greet(name: string): string {.flow.} =
  delay(10)                       # wait 10 ms without blocking the thread
  "hello " & name

echo greet("world")               # a flow proc is also a normal proc
```

`{.flow.}` marks a proc that may pause. `delay` is a pause point. Call it from plain
code and it just runs (driving the event loop for you).

## 2. Tasks: doing things at the same time

```nim
import stagelane

proc work(id, ms: int): int {.flow.} =
  delay(ms)
  id * 10

proc main(): int {.flow.} =
  let a = go work(1, 30)          # start, do not wait
  let b = go work(2, 10)
  let c = go work(3, 20)
  await(a) + await(b) + await(c)  # total time ~30 ms, not 60

echo run main()
```

* `go f(x)` starts a task and returns a handle. If `f` can never pause (see
  `neverSuspends`), it has nothing to interleave with, so it simply runs to completion
  inside `go` and the handle you get is already finished. Behaviour is the same, it
  just costs a few nanoseconds instead of a task. (`-d:flowNoInlineGo` turns this off.)
* `await t` waits and gives you the value (or re-raises the task's exception).
* `run f(x)` is the program entry: it runs the event loop until `f` is done.

## 3. Time, timeouts, cancellation

```nim
import stagelane

proc slow(): string {.flow.} =
  try:
    delay(10_000)
    "finished"
  except CancelledError:
    "stopped early"                # cleanup code runs as usual

proc main() {.flow.} =
  let t = go slow()
  yieldNow()                       # let it start
  cancel(t)
  echo await(t)
  try:
    echo withTimeout(50, slow())
  except TimeoutError:
    echo "timed out"

run main()
```

`cancel` wakes the task wherever it is parked (delay, channel, lock, socket, await) with
a `CancelledError`. A busy loop that never pauses should call `checkpoint()` now and
then, or it cannot be cancelled.

## 4. Scopes: tasks that cannot leak

```nim
import stagelane

proc ok(n: int): int {.flow.} =
  delay(5)
  n

proc bad() {.flow.} =
  delay(1)
  raise newException(ValueError, "boom")

proc main() {.flow.} =
  try:
    scope s:
      discard s.go ok(1)
      discard s.go bad()
      discard s.go ok(3)
  except ValueError as e:
    echo "scope failed: ", e.msg    # siblings were cancelled first

run main()
```

A `scope` block does not finish until every task started with `s.go` is finished.
The first failure cancels the rest, then is re-raised. Prefer `scope` over loose `go`.

Two things the scope does for you in a big fan-out: children that finished successfully
are dropped from its bookkeeping (a scope that starts a million short tasks does not
hold a million finished tasks), and `s.go` is a *spawn point*: when the run queue
already holds `flowSpawnHighWater` (default 1024) continuations, the spawner yields
once so they can run before it starts more. That keeps the working set small and the
CPU cache hot. It only happens in a burst of spawns of tasks that can pause; code that
starts a few tasks never notices. `-d:flowSpawnHighWater=0` disables it.

## 5. Channels and select

```nim
import stagelane

proc producer(ch: Chan[int]) {.flow.} =
  for i in 1..5: ch.send(i)         # waits when the buffer is full
  ch.close()

proc consumer(ch: Chan[int]): int {.flow.} =
  eachRecv(ch, v):                  # loops until closed and drained, no exception
    result += v
  # same thing by hand: `let v = ch.recvOpt()` is `none` once closed and drained

proc main() {.flow.} =
  let ch = newChan[int](2)          # buffer of 2: back-pressure for free
  discard go producer(ch)
  echo await(go consumer(ch))       # 15

  let a = newChan[string](1)
  let b = newChan[string](1)
  discard a.trySend("from a")
  select:
    a.recv(x): echo x
    b.recv(y): echo y
    timeout(100): echo "nothing arrived"

run main()
```

`select` takes `chan.recv(name): body`, `chan.send(value): body`, `timeout(ms): body`
and optionally `default: body` (never waits).

## 6. Locks, permits, events

```nim
import stagelane

var shared = 0

proc bump(m: Mutex, n: int) {.flow.} =
  for _ in 1..n:
    withLock(m):
      let old = shared
      yieldNow()                    # another task could run here without the lock
      shared = old + 1

proc main() {.flow.} =
  let m = newMutex()
  scope s:
    discard s.go bump(m, 50)
    discard s.go bump(m, 50)
  echo shared                       # 100

run main()
```

Also: `Semaphore` (`withPermit`) to limit concurrency, `Event` (`set`/`wait`),
`WaitGroup`.

## 7. Errors

Exceptions behave as you expect. They propagate to whoever awaits, `try/except/finally`
and `defer` work across pauses, and a failed task re-raises at `await`.

```nim
import stagelane

proc risky(n: int): int {.flow.} =
  delay(1)
  if n mod 2 == 1: raise newException(ValueError, "odd: " & $n)
  n

proc main() {.flow.} =
  for i in 1..3:
    try:
      echo await(go risky(i))
    except ValueError as e:
      echo "caught ", e.msg
    finally:
      echo "done ", i

run main()
```

## 8. Network

```nim
import stagelane, stagelane/net

proc session(c: TcpStream) {.flow.} =
  try:
    while true:
      let line = c.readLine()
      c.write("echo: " & line & "\n")
  except IOError: discard           # peer closed
  c.close()

proc server(l: TcpListener) {.flow.} =
  for _ in 1..2:                    # a real server would loop forever
    discard go session(l.accept())

proc client(port: int): string {.flow.} =
  let c = connectTcp("127.0.0.1", port)
  c.write("hi\n")
  result = c.readLine()
  c.close()

proc main() {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let srv = go server(l)
  echo await(go client(l.localPort))
  echo await(go client(l.localPort))
  await(srv)
  l.close()

run main()
```

One task per connection is just a couple of small heap objects. Reading and writing
pause only when the socket is not ready.

### Fast servers

Three things matter when a server handles many connections:

* **Sockets stay registered.** On Linux, sockets from `stagelane/net` are registered with
  the kernel once (edge-triggered) instead of once per pause, and a read that is known to
  have emptied the socket does not probe it again. An idle keep-alive request costs 2
  syscalls (`recv`, `send`) instead of 5. Nothing to do; it is on by default.
* **No allocation per read.** `readSome` returns a new string. `recvInto(buf, n)` and
  `sendFrom(buf, n)` use memory you own and reuse.
* **Handlers and receivers.** `serveTcp(listener, handler, ctx...)` runs `handler(ctx..., conn)`
  per connection: extra arguments (a server object, a config) are evaluated once and passed in
  front of the connection; a `ref` is shared by all connections. `serveTcp(listener, handler)` takes the *name* of a flow proc, resolved at
  compile time, or a flow proc held in a value (`flowFn(handler)`, see
  [flow procs as values](#flow-procs-as-values)); either way the handler may pause like any
  flow proc (`delay`, channels, other sockets).

```nim
import stagelane, stagelane/net, stagelane/uring

discard ringEnable()          # io_uring where the kernel has it; a no-op returning false elsewhere

proc echoOnce(c: TcpStream) {.flow.} =
  var buf = newString(256)
  let n = c.recvInto(addr buf[0], buf.len)
  if n > 0: c.sendFrom(addr buf[0], n)
  c.close()

proc server(l: TcpListener) {.flow.} = serveTcp(l, echoOnce)

proc client(port: int): string {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  s.write("fast")
  result = s.readSome(16)
  s.close()

proc main() {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  scope g:
    let srv = go(g, server(l))
    echo await(go(g, client(l.localPort)))      # fast
    srv.cancel()                                # the accept loop never ends by itself
  l.close()

run main()
```

**io_uring (Linux 5.11+, opt-in).** `ringEnable()` (once per thread, before the first
I/O) switches `stagelane/net` to completion-based I/O: every operation a loop turn produces
goes to the kernel in one `io_uring_enter`, and the results are read back from shared
memory. On the HTTP benchmark that is 0.2 syscalls per request instead of 2. Whether it
also saves CPU depends on what a syscall costs where you deploy: on a loopback test in a
VM the kernel's TCP work dominates and CPU per request is about equal; with mitigations,
sandboxes or many connections per loop turn the saving grows. `ringEnable()` returns
`false` and changes nothing if the kernel cannot do it, so the same code runs everywhere.

`stagelane/uring` also exposes the operations themselves: `ringRecv`, `ringSend`,
`ringAccept`, `ringConnect`, `ringRead`, `ringWrite` (regular files too, which epoll cannot
do). They return the kernel's result (a value >= 0 or `-errno`), take caller-owned buffers
and, if the task is cancelled while waiting, resume only after the kernel has stopped using
the buffer. Sockets used this way must be in blocking mode; `stagelane/net` handles that.

## 9. More than one thread

```
nim c --threads:on --mm:atomicArc -d:flowThreads app.nim
```

```nim threads
import stagelane, stagelane/exec

proc crunch(n: int): int {.flow.} =
  for i in 1..n: result += i mod 7

proc main() {.flow.} =
  let pool = newPool(4)             # 4 worker threads, each with its own event loop
  var jobs: seq[Task[int]]
  for i in 1..8: jobs.add pool.go crunch(1_000_000 * i)
  var total = 0
  for j in jobs: total += await(j)  # await works across threads
  echo total
  pool.shutdown()

run main()
```

Do not need the result? `pool.spawn f(x)` starts a task *without* a handle: one
allocation, no completion bookkeeping, noticeably cheaper than `pool.go`. Use a
`Latch` (a thread-safe countdown) or a `SharedChan` to learn that the work is done:

```nim threads
import stagelane, stagelane/exec
import std/atomics

var hits: Atomic[int]

proc tick(l: Latch) {.flow.} =
  discard hits.fetchAdd(1)
  l.countDown()                     # callable from any thread

proc main() {.flow.} =
  let pool = newPool(4)
  let l = newLatch(1000)
  for i in 1..1000: pool.spawn tick(l)
  wait(l)                           # suspends until the count reaches zero
  echo hits.load()                  # 1000
  pool.shutdown()

run main()
```

An exception that escapes a `spawn`ed task is not caught by anything (there is no
handle to carry it), exactly like an unhandled exception in a thread: catch inside the
task if it can fail. A spawner that posts `flowSpawnBurst` (default 512) items in a
row yields the CPU once so the workers can drain what is queued.

Why `atomicArc`? Task handles, wait queues and channels are shared between threads,
and plain ARC/ORC count references non-atomically. Programs that never create a
`Pool` use plain `--mm:arc` or `--mm:orc` (also with `--threads:on`, Nim's default) and
pay nothing. With `atomicArc` the scheduler core runs at the same speed; only
operations that really share objects (spawn + await, channels) cost up to ~1.5x more.

**Where tasks go.** `newPool(n)` hands tasks to its workers in turn (cheapest: nothing is
shared between spawning threads). When tasks differ a lot in how long they live (one task per
connection, say), create the pool with `newPool(n, balLeastLoaded)`: every `go`/`spawn` then looks
at two random workers and picks the one with fewer unfinished tasks, so a worker that is stuck
behind a long task stops receiving new ones. `pool.load(i)` and `pool.leastLoaded()` (for
`goAt`) expose the counts; they are only kept by least-loaded pools. Placement is decided
when a task is started: a task never moves afterwards, and tasks already queued behind a
long CPU-bound one are not stolen (see [internals](internals.md#placement)).

`newPool(n, ring = true)` gives every worker its own io_uring (Linux 5.11+, see the server
section above); sockets created by a task on such a worker are in ring mode.

A task stays on the thread that took it. `Chan`, `Mutex` etc. belong to one thread;
to move data between threads use `SharedChan[T]`. To use a blocking library, wrap
the blocking call in a one-line flow proc and `pool.go` it (see [why.md](why.md)).

## Flow procs as values

A flow proc cannot go into a `proc` variable (calling it has to be known to possibly pause), but
`flowFn(name)` makes a value that can be stored, passed and started later. Its type is
`FlowFn[proc (params): Result]`; start it with `call` (inside a flow proc it may pause; anywhere
else it blocks like calling the proc directly) or run it as a task with `go`, `scope.go`,
`pool.go` or `pool.spawn`. Leading arguments can be *bound*:

```nim
import stagelane, std/tables

proc greet(greeting, name: string): string {.flow.} =
  delay(1)
  greeting & ", " & name

type Handler = FlowFn[proc (name: string): string]

proc main() {.flow.} =
  var routes = initTable[string, Handler]()
  routes["en"] = flowFn(greet, "hello")      # binds `greeting`; `name` stays open
  routes["de"] = flowFn(greet, "hallo")
  echo routes["en"].call("world")            # may pause, like any flow call
  let t = go routes["de"].call("welt")       # or run it as a task
  echo await(t)

run main()
```

What it is: the value holds the proc's *continuation constructor* plus its bound arguments, so
starting it costs what starting the proc costs plus one indirect call. What it is not:
a closure over your locals (a continuation owns its arguments by value, so bind values, not
variables). Limits: up to 8 open parameters, no `var` parameters, the proc has to be named
(a lambda marked `{.flow.}` is rejected) and declared at module level, like every flow proc;
generic procs work once instantiated (`flowFn(f[int])`); default values of parameters must be
passed explicitly to `call`.

## 10. Tips

* `neverSuspends(f(x))` is true when `f` compiles to plain native code.
* `{.flow, heap.}` forces heap frames, for recursion deeper than the C stack.
* Long CPU loops inside a task: `checkpoint()` or `yieldNow()` now and then.
* `-d:flowStats` prints how small each proc's frame ended up.
* Compile-time knobs: `-d:flowNoInlineGo` (always run `go` as a task),
  `-d:flowSpawnHighWater=N` (0 = off), `-d:flowSpawnBurst=N` (0 = off).
* Build for speed with `-d:danger`; add `-d:flowAcyclic` under ORC if your locals hold
  no reference cycles.

## Limits

* Generic flow procs work (`proc f[T](x: T)`, `typedesc` and `static` parameters). Every
  explicit generic parameter must be deducible from a parameter type (add
  `_: typedesc[T]` if not). Generic flow procs always take the suspendable path
  (no native fast path, no frame pooling), and a type-class parameter such as
  `x: SomeInteger` needs an explicit `[T: SomeInteger]`.
* `openArray` / `varargs` parameters are copied into the frame when the proc is called
  (read-only snapshot). `var` parameters are accepted only on flow procs that never
  suspend; those can be called but not spawned. Otherwise pass a `ref`.
* Local `proc`/`type` declarations only in scopes that do not pause. Closures are fine.
* A `for` over an arbitrary iterator whose body pauses runs over a snapshot. Ranges,
  `items`, `pairs`, `mitems`, `mpairs` on seq/array/string are exact. Tuple
  destructuring `for (a, b) in ..` works everywhere, including `mitems` (the names alias
  the element's fields in place).
* A flow proc cannot be stored in a `proc` variable; use `flowFn` (see above). A flow proc
  declared *inside* another proc is not supported (declare it at module level).
* `select` works on `Chan`, not `SharedChan`. Sockets work on POSIX and Windows ([windows.md](windows.md)).
* `scope` notices a failing child as soon as it fails (completion order) for children
  that run on the scheduler thread of the scope; children on other threads are waited
  for in spawn order.
* Pragmas such as `{.cast(gcsafe).}:` blocks are kept around the code they enclose.
  `inline`/`cdecl`-style pragmas on the proc apply to its direct (callable) form.

## When something does not compile

| message | usually means |
|---|---|
| `parameter .. is var, which cannot live in a suspendable frame` | the proc suspends: pass a `ref`, or return the new value |
| `generic parameter .. must appear in a parameter type` | add `_: typedesc[T]` |
| `ambiguous call ... sleep` | you used `os.sleep`; stagelane's is `delay` |
| `a suspension point may not appear inside this kind of expression` | pull the call out into a `let` |
| the unexpected: output mentions `flowC` | a bug in stagelane, please report with the proc |

## Errors you may want to catch

* `DeadlockError` comes out of `run` (not out of a flow proc: by then nothing can run).
  The message says what the awaited task is parked on and how many tasks are alive.
* `recv` on a closed, drained channel raises `RecvOnClosedError`; `send` after `close`
  raises `SendOnClosedError`. Both derive from `ChanClosedError`. Prefer `eachRecv` or
  `recvOpt` to detect shutdown without an exception.
