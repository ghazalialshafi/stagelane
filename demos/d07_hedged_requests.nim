## 07 - "First result wins" (hedged requests): ask 3 replicas, take the fastest,
## cancel the others. Great for tail-latency. Cancelled replicas clean up via `except CancelledError`.
import std/[strformat, monotimes, times]
import stagelane

var cancelledReplicas = 0

proc replica(name: string, ms: int, ch: Chan[string]) {.flow.} =
  var finished = false
  try:
    delay(ms)
    discard ch.trySend(name & " answered in " & $ms & "ms")
    finished = true
  finally:
    if not finished: inc cancelledReplicas   # cancelled: release connections etc. here

proc hedged(q: int): string {.flow.} =
  let ch = newChan[string](3)
  let lat = [40 + (q * 37) mod 90, 20 + (q * 53 + 1) mod 120, 30 + (q * 71) mod 100]
  let a = go replica("replica-A", lat[0], ch)
  let b = go replica("replica-B", lat[1], ch)
  let c = go replica("replica-C", lat[2], ch)
  result = ch.recv()
  cancel(a); cancel(b); cancel(c)

proc main() {.flow.} =
  let t0 = getMonoTime()
  scope s:
    var tasks: seq[Task[string]]
    for q in 1..5: tasks.add s.go hedged(q)
    for i, t in tasks: echo &"query {i + 1}: {await(t)}"
  echo &"total {(getMonoTime() - t0).inMilliseconds} ms; losing replicas cancelled: {cancelledReplicas}"

run main()
