## 19 - Offload BLOCKING code to a thread pool without freezing the event loop.
## Build: nim c --threads:on --mm:atomicArc -d:flowThreads -d:danger d19_offload_blocking.nim
##
## A heartbeat task ticks every 10 ms on the main loop and records its worst gap.
##   A) 8 blocking "DB queries" (50 ms each) called directly  -> loop frozen ~400 ms
##   B) the same 8 queries on a Pool of 8 workers             -> ~50 ms total, loop stays smooth
import std/[os, strformat, monotimes, times]
import stagelane, stagelane/exec

proc blockingQuery(ms: int): int =             # plain, blocking third-party style code
  os.sleep(ms)
  ms

proc query(ms: int): int {.flow.} = blockingQuery(ms)   # one-line flow wrapper

var worstGapMs = 0

proc heartbeat(stop: Event) {.flow.} =
  var last = getMonoTime()
  while not stop.isSet:
    delay(10)
    let now = getMonoTime()
    worstGapMs = max(worstGapMs, int((now - last).inMilliseconds))
    last = now

proc blockingOnLoop(): int {.flow.} =
  for _ in 1..8: result += query(50)           # each call blocks the whole event loop

proc offloaded(pool: Pool): int {.flow.} =
  var jobs: seq[Task[int]]
  for _ in 1..8: jobs.add pool.go query(50)    # runs on worker threads
  for j in jobs: result += await(j)

proc measure(name: string, pool: Pool, useGool: bool) {.flow.} =
  let stop = newEvent()
  worstGapMs = 0
  let hb = go heartbeat(stop)
  delay(30)
  let t0 = getMonoTime()
  let r = if useGool: offloaded(pool) else: blockingOnLoop()
  let ms = (getMonoTime() - t0).inMilliseconds
  stop.set()
  await(hb)
  echo &"{name}: {ms:>4} ms total, result {r}, worst heartbeat gap {worstGapMs} ms"

proc main() {.flow.} =
  let pool = newPool(8)
  measure("A) blocking on the loop ", pool, false)
  measure("B) offloaded to 8 threads", pool, true)
  pool.shutdown()

run main()
