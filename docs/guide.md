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

* `go f(x)` starts a task and returns a handle.
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

Why `atomicArc`? Task handles, wait queues and channels are shared between threads,
and plain ARC/ORC count references non-atomically. Programs that never create a
`Pool` use plain `--mm:arc` or `--mm:orc` (also with `--threads:on`, Nim's default) and
pay nothing. With `atomicArc` the scheduler core runs at the same speed; only
operations that really share objects (spawn + await, channels) cost up to ~1.5x more.

A task stays on the thread that took it. `Chan`, `Mutex` etc. belong to one thread;
to move data between threads use `SharedChan[T]`. To use a blocking library, wrap
the blocking call in a one-line flow proc and `pool.go` it (see [why.md](why.md)).

## 10. Tips

* `neverSuspends(f(x))` is true when `f` compiles to plain native code.
* `{.flow, heap.}` forces heap frames, for recursion deeper than the C stack.
* Long CPU loops inside a task: `checkpoint()` or `yieldNow()` now and then.
* `-d:flowStats` prints how small each proc's frame ended up.
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
* A flow proc cannot be stored in a `proc` variable yet.
* `select` works on `Chan`, not `SharedChan`. Sockets are POSIX only.
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
