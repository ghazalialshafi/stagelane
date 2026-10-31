## 06 - Retry with per-attempt timeout and exponential back-off.
## 20 flaky "services" are called concurrently; each fails/hangs randomly,
## but retries make them all succeed. Everything stays on one thread.
import std/[random, strformat, monotimes, times]
import stagelane

var totalAttempts, timeouts, errors = 0

proc flakyCall(id, attempt: int): string {.flow.} =
  inc totalAttempts
  let roll = rand(99)
  if roll < 25: delay(500)         # hangs -> will hit the timeout
  elif roll < 50:
    delay(3); raise newException(IOError, "503 from service " & $id)
  else: delay(5 + rand(10))
  "service" & $id & " ok"

proc withRetry(id: int): string {.flow.} =
  for attempt in 1..8:
    try:
      return withTimeout(40, flakyCall(id, attempt))
    except TimeoutError: inc timeouts
    except IOError: inc errors
    delay(5 * (1 shl min(attempt, 4)))   # exponential back-off
  raise newException(IOError, "service " & $id & " gave up")

proc main() {.flow.} =
  randomize(42)
  let t0 = getMonoTime()
  var ok = 0
  scope s:
    var tasks: seq[Task[string]]
    for id in 1..20: tasks.add s.go withRetry(id)
    for t in tasks:
      discard await(t); inc ok
  echo &"{ok}/20 succeeded after {totalAttempts} attempts ({timeouts} timeouts, {errors} errors)"
  echo &"elapsed {(getMonoTime() - t0).inMilliseconds} ms"

run main()
