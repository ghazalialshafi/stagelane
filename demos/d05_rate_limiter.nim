## 05 - Concurrency limit with a Semaphore: 60 requests, at most 5 in flight.
## Shows the observed peak never exceeds the limit while throughput stays high.
import std/[monotimes, times, strformat]
import stagelane

var running, peak, completed = 0

proc request(sem: Semaphore, i: int) {.flow.} =
  withPermit(sem):
    inc running
    peak = max(peak, running)
    delay(20)
    dec running
    inc completed

proc main() {.flow.} =
  let sem = newSemaphore(5)
  let t0 = getMonoTime()
  scope s:
    for i in 1..60: discard s.go request(sem, i)
  echo &"completed {completed}, peak concurrency {peak} (limit 5)"
  echo &"elapsed {(getMonoTime() - t0).inMilliseconds} ms (ideal 60/5*20 = 240 ms)"
  doAssert peak == 5

run main()
