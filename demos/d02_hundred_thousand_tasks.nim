## 02 - Scale: 100,000 simultaneously-sleeping tasks on ONE thread.
## An OS thread each would need ~100 GB of stack. Here it is a few hundred MB at most.
import std/[monotimes, times, strformat]
import stagelane

var woke = 0

proc sleeper(i: int) {.flow.} =
  delay(100 + i mod 50)            # 100..149 ms
  inc woke

proc main() {.flow.} =
  const N = 100_000
  let t0 = getMonoTime()
  scope s:
    for i in 0 ..< N: discard s.go sleeper(i)
    echo &"spawned {N} tasks in {(getMonoTime() - t0).inMilliseconds} ms (all parked on timers)"
  echo &"woke {woke} tasks, total {(getMonoTime() - t0).inMilliseconds} ms"
  doAssert woke == N

run main()
