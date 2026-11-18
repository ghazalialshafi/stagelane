# Load accounting and placement of `Pool` (balLeastLoaded / balRoundRobin).
import ../src/stagelane
import ../src/stagelane/exec
import std/[atomics, os]

var hits: array[8, Atomic[int]]
var tids: array[8, int]

proc whoami(): int {.flow.} = getThreadId()
proc blockFor(ms: int): int {.flow.} =
  sleep(ms)                      # blocks the worker thread on purpose
  1
proc tick(slot: int, l: Latch) {.flow.} =
  discard hits[slot].fetchAdd(1)
  l.countDown()
proc tock(x: int): int {.flow.} = x + 1

proc slotOf(tid: int, n: int): int =
  for i in 0..<n:
    if tids[i] == tid: return i
  -1

proc viaValue(x: int): int {.flow.} = yieldNow(); x + 1
proc countOne(l: Latch) {.flow.} = l.countDown()

proc settle(p: Pool) =
  # `done` is bumped just after the task's last statement: give it a moment
  for _ in 0..200:
    var busy = 0
    for i in 0..<p.n: busy += p.load(i)
    if busy == 0: return
    sleep(5)

proc mainTest() {.flow.} =
  # 1. least-loaded: counters return to zero after go and spawn
  let p = newPool(4, balLeastLoaded)
  for i in 0..<4: tids[i] = await(p.goAt(i, whoami()))
  var jobs: seq[Task[int]]
  for i in 0..<500: jobs.add p.go tock(i)
  var s = 0
  for j in jobs: s += await(j)
  doAssert s == 500 * 501 div 2, "go results"
  let l = newLatch(500)
  for i in 0..<500: p.spawn tick(0, l)
  wait(l)
  settle(p)
  for i in 0..<4: doAssert p.load(i) == 0, "load must drain, worker " & $i & " = " & $p.load(i)
  echo "ok load drains to zero"

  # 2. a worker stuck in a long blocking task receives (almost) nothing new
  let stuck = p.goAt(0, blockFor(400))
  sleep(50)
  doAssert p.load(0) >= 1 and p.leastLoaded() != 0, "stuck worker looks loaded"
  for i in 0..<8: hits[i].store(0)
  # (paced: a burst would queue up behind the stuck worker in step with the others)
  var onStuck = 0
  for i in 0..<200:
    if slotOf(await(p.go whoami()), 4) == 0: inc onStuck
  doAssert onStuck < 20, "least-loaded kept feeding the busy worker: " & $onStuck & "/200"
  discard await(stuck)
  echo "ok busy worker avoided (", onStuck, "/200 on it)"
  p.shutdown()

  # 2b. flow procs held in values run on workers too
  let pv = newPool(2, balLeastLoaded)
  let fv = flowFn(viaValue)
  var vs: seq[Task[int]]
  for i in 0..<100: vs.add pv.go fv.call(i)
  var sum = 0
  for v in vs: sum += await(v)
  doAssert sum == 100 * 101 div 2, "values on the pool"
  let lv = newLatch(100)
  let cv: FlowFn[proc (l: Latch)] = flowFn(countOne)
  for i in 0..<100: pv.spawn cv.call(lv)
  wait(lv)
  settle(pv)
  doAssert pv.load(0) == 0 and pv.load(1) == 0
  pv.shutdown()
  echo "ok FlowFn on a pool"

  # 3. round robin still spreads evenly and keeps no counters
  let r = newPool(4, balRoundRobin)
  for i in 0..<4: tids[i] = await(r.goAt(i, whoami()))
  var cnt: array[4, int]
  var hs2: seq[Task[int]]
  for i in 0..<400: hs2.add r.go whoami()
  for h in hs2: inc cnt[slotOf(await(h), 4)]
  for i in 0..<4: doAssert cnt[i] == 100, "round robin share " & $cnt
  doAssert r.load(0) == 0
  r.shutdown()
  echo "ok round robin even"

run mainTest()
echo "all ok"
