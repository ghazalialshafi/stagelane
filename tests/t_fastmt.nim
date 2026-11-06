import ../src/stagelane
import ../src/stagelane/exec
import std/atomics
# multi-thread fast paths: lock-free mailbox with many producers, detached spawn,
# Latch, lazy completion queues, cross-thread await/cancel.

var hits: Atomic[int]
proc bump(x: int, l: Latch) {.flow.} =
  discard hits.fetchAdd(x)
  l.countDown()
proc val(x: int): int {.flow.} = x * 2
proc slowVal(x: int): int {.flow.} =
  yieldNow(); yieldNow()
  x + 1
proc sleeper(): string {.flow.} =
  try:
    delay(10_000); result = "slept"
  except CancelledError: result = "cancelled"

let pool = newPool(4)

# 1. detached spawn from the main thread, Latch wait
proc t1(): int {.flow.} =
  let l = newLatch(20_000)
  for i in 0..<20_000: pool.spawn bump(1, l)
  wait(l)
  hits.load()
doAssert runTask(go t1()) == 20_000
echo "ok detached spawn + latch"

# 2. many producer threads posting into ONE consumer mailbox (the main scheduler):
#    workers spawn tasks back onto the main thread's pool slot via completions
proc inner(x: int): int {.flow.} =
  yieldNow()
  x
proc fan(p: Pool, base: int): int {.flow.} =
  var ts: seq[Task[int]]
  for i in 0..<500: ts.add p.go inner(base + i)
  for t in ts: result += await(t)
proc t2(): int {.flow.} =
  var ts: seq[Task[int]]
  for k in 0..<8: ts.add pool.go fan(pool, k * 1000)
  for t in ts: result += await(t)
var want = 0
for k in 0..<8:
  for i in 0..<500: want += k * 1000 + i
doAssert runTask(go t2()) == want
echo "ok nested pool fan-out (", want, ")"

# 3. go + await, 50k handles
proc t3(): int {.flow.} =
  var ts: seq[Task[int]]
  for i in 0..<50_000: ts.add pool.go val(i)
  for t in ts: result += await(t)
var w3 = 0
for i in 0..<50_000: w3 += i * 2
doAssert runTask(go t3()) == w3
echo "ok 50k pool.go handles"

# 4. await a not-yet-finished cross-thread task from several awaiters (lazy doneq)
proc waiter(t: Task[int]): int {.flow.} = await(t)
proc t4(): int {.flow.} =
  let job = pool.go slowVal(41)
  var ws: seq[Task[int]]
  for i in 0..<20: ws.add go waiter(job)
  for w in ws: result += await(w)
doAssert runTask(go t4()) == 20 * 42
echo "ok many awaiters on one cross-thread task"

# 5. cancel a task parked on a worker
proc t5(): string {.flow.} =
  let s = pool.go sleeper()
  delay(20)
  s.cancel()
  await(s)
doAssert runTask(go t5()) == "cancelled"
echo "ok cross-thread cancel"

# 6. repeated pool start/stop (no hang / leak of the new mailbox)
proc runIt(p: Pool, l: Latch): int {.flow.} =
  for i in 0..<100: p.spawn bump(0, l)
  wait(l)
  1
for k in 0..<20:
  let p = newPool(3)
  let l = newLatch(100)
  doAssert runTask(go runIt(p, l)) == 1
  p.shutdown()
echo "ok pool churn"
pool.shutdown()
echo "all ok"
