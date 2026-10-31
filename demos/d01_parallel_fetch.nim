## 01 - Parallel fetch: 100 slow "API calls" finish in the time of ONE.
## Sequential would take ~3 s; with tasks it takes ~30 ms on a single thread.
import std/[monotimes, times, strformat]
import stagelane

proc fetchUser(id: int): string {.flow.} =
  delay(30)                        # pretend network latency
  "user#" & $id

proc sequential(n: int): int {.flow.} =
  for i in 1..n:
    result += fetchUser(i).len

proc concurrent(n: int): int {.flow.} =
  var tasks: seq[Task[string]]
  for i in 1..n: tasks.add go fetchUser(i)
  for t in tasks: result += await(t).len

proc main() {.flow.} =
  let n = 100
  var t0 = getMonoTime()
  let a = sequential(n)
  let seqMs = (getMonoTime() - t0).inMilliseconds
  t0 = getMonoTime()
  let b = concurrent(n)
  let conMs = (getMonoTime() - t0).inMilliseconds
  doAssert a == b
  echo &"sequential : {seqMs} ms"
  echo &"concurrent : {conMs} ms   (speedup x{seqMs div max(conMs, 1)})"

run main()
