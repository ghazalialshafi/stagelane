import stagelane
when defined(flowThreads):
  import stagelane/exec
import std/[monotimes, times, os, strutils, atomics]

var sink: int

proc report(name: string, ops: int, t0: MonoTime) =
  let us = (getMonoTime() - t0).inMicroseconds
  echo "RESULT\tstagelane\t", name, "\t", ops, "\t", us

proc leaf(x: int): int {.flow.} =
  if x < 0: yieldNow()
  result = x + 1
proc caller(n: int): int {.flow.} =
  for i in 0..<n: result += leaf(i)

proc yielder(n: int) {.flow.} =
  for i in 0..<n: yieldNow()

proc tiny(x: int): int {.flow.} = x
proc y3() {.flow.} =
  yieldNow(); yieldNow(); yieldNow()

proc pinger(a, b: Chan[int], n: int) {.flow.} =
  for i in 0..<n:
    a.send(i)
    discard b.recv()
proc ponger(a, b: Chan[int], n: int) {.flow.} =
  for i in 0..<n: b.send(a.recv() + 1)

when defined(flowThreads):
  var doneCount: Atomic[int]
  proc tinyd(x: int, l: Latch) {.flow.} =
    discard doneCount.fetchAdd(x and 1, moRelaxed)
    l.countDown()

proc sleeper(ms: int) {.flow.} = delay(ms)

proc crunch(n: int): int {.flow.} =
  for i in 1..n: result += i mod 7

proc producer(c: Chan[int], n: int) {.flow.} =
  for i in 0..<n: c.send(i)
proc consumer(c: Chan[int], n: int): int {.flow.} =
  for i in 0..<n: result += c.recv()

proc main(w: int, only: string, pn: int) {.flow.} =
  template want(n: string): bool = only == "" or only == n
  var t0: MonoTime
  if want "call":
    t0 = getMonoTime(); sink += caller(10_000_000); report("call_10M", 10_000_000, t0)
  if want "yield":
    t0 = getMonoTime(); yielder(2_000_000); report("yield_2M", 2_000_000, t0)
  if want "spawn":
    when defined(flowThreads):
      if w > 0:
        let pool = newPool(w)                 # pool start/stop is outside the timed
        t0 = getMonoTime()                    # region, like Nimony's initPool
        var jobs: seq[Task[int]]
        for i in 0..<200_000: jobs.add pool.go tiny(i)
        for j in jobs: sink += await(j)
        report("spawn_200k", 200_000, t0)
        pool.shutdown()
      else:
        t0 = getMonoTime()
        scope g:
          for i in 0..<200_000: discard go(g, tiny(i))
        report("spawn_200k", 200_000, t0)
    else:
      t0 = getMonoTime()
      scope g:
        for i in 0..<200_000: discard go(g, tiny(i))
      report("spawn_200k", 200_000, t0)
  if want "spawnd":
    # fire-and-forget on the pool (no result handle), completion via a latch:
    # the same shape as the Nimony benchmark (submit + atomic done counter)
    when defined(flowThreads):
      if w > 0:
        let pool = newPool(w)
        t0 = getMonoTime()
        let l = newLatch(200_000)
        for i in 0..<200_000: pool.spawn tinyd(i, l)
        wait(l)
        report("spawn_detached_200k", 200_000, t0)
        pool.shutdown()
  if want "fanout":
    t0 = getMonoTime()
    scope g:
      for i in 0..<100_000: discard go(g, y3())
    report("fanout_100k_x3yield", 400_000, t0)
  if want "pingpong":
    let a = newChan[int](1)
    let b = newChan[int](1)
    t0 = getMonoTime()
    let p = go pinger(a, b, 200_000)
    let q = go ponger(a, b, 200_000)
    await(p); await(q)
    report("pingpong_200k", 400_000, t0)
  if want "timers":
    t0 = getMonoTime()
    scope g:
      for i in 0..<100_000: discard go(g, sleeper(1 + i mod 5))
    report("timers_100k", 100_000, t0)
  if want "cpu":
    when defined(flowThreads):
      if w > 0:
        let pool = newPool(w)
        t0 = getMonoTime()
        var jobs: seq[Task[int]]
        for i in 0..<64: jobs.add pool.go crunch(2_000_000)
        for j in jobs: sink += await(j)
        report("cpu_64x2M", 64, t0)
        pool.shutdown()
      else:
        t0 = getMonoTime()
        for i in 0..<64: sink += crunch(2_000_000)
        report("cpu_64x2M", 64, t0)
    else:
      t0 = getMonoTime()
      for i in 0..<64: sink += crunch(2_000_000)
      report("cpu_64x2M", 64, t0)
  if want "pipe":
    let c = newChan[int](128)
    t0 = getMonoTime()
    let p = go producer(c, pn)
    let q = go consumer(c, pn)
    await(p); sink += await(q)
    report("chan_pipe_" & $pn, pn, t0)

let w = if paramCount() >= 1: parseInt(paramStr(1)) else: 0
let only = if paramCount() >= 2: paramStr(2) else: ""
let pn = if paramCount() >= 3: parseInt(paramStr(3)) else: 20_000
run main(w, only, pn)
echo "sink ", sink
