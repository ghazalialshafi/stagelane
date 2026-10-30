# Recipes

Short, copy-paste patterns. All of these are compiled by `tests/docs_check.sh`.

## Worker pool over a channel

```nim
import stagelane

proc worker(id: int, jobs: Chan[int], results: Chan[string]) {.flow.} =
  while true:
    let j = jobs.recvOpt()
    if j.isNone: break
    delay(5)
    results.send("w" & $id & " did " & $j.get)

proc main() {.flow.} =
  let jobs = newChan[int](10)
  let results = newChan[string](10)
  scope s:
    for id in 1..3: discard s.go worker(id, jobs, results)
    for j in 1..6: jobs.send(j)
    jobs.close()                    # workers stop when drained
  var n = 0
  while results.len > 0:
    discard results.recv(); inc n
  echo n, " results"

run main()
```

## Retry with a deadline

```nim
import stagelane

var attempts = 0
proc flaky(): string {.flow.} =
  delay(2)
  inc attempts
  if attempts < 3: raise newException(IOError, "try again")
  "ok after " & $attempts

proc retry(): string {.flow.} =
  for i in 1..5:
    try:
      return withTimeout(100, flaky())
    except IOError, TimeoutError:
      delay(10 * i)                 # back off
  raise newException(IOError, "gave up")

echo retry()
```

## Limit concurrency

```nim
import stagelane

proc job(s: Semaphore, i: int, running, peak: ptr int) {.flow.} =
  withPermit(s):
    inc running[]
    peak[] = max(peak[], running[])
    delay(5)
    dec running[]

proc main() {.flow.} =
  var running, peak = 0
  let s = newSemaphore(3)           # at most 3 at once
  scope g:
    for i in 1..10: discard g.go job(s, i, addr running, addr peak)
  echo "peak ", peak                # 3

run main()
```

## First result wins

```nim
import stagelane

proc source(name: string, ms: int, ch: Chan[string]) {.flow.} =
  delay(ms)
  discard ch.trySend(name)

proc main() {.flow.} =
  let first = newChan[string](3)
  let a = go source("slow", 50, first)
  let b = go source("fast", 5, first)
  echo first.recv()                 # fast
  cancel(a); cancel(b)

run main()
```

## Periodic work with clean shutdown

```nim
import stagelane

proc ticker(stop: Event): int {.flow.} =
  while not stop.isSet:
    inc result
    delay(10)

proc main() {.flow.} =
  let stop = newEvent()
  let t = go ticker(stop)
  delay(55)
  stop.set()                        # ask it to finish, then wait
  echo "ticks: ", await(t) > 3

run main()
```

## Timeout around a whole block

```nim
import stagelane

proc steps() {.flow.} =
  delay(10); delay(10); delay(10)

proc main() {.flow.} =
  try:
    withTimeout(15, steps())
  except TimeoutError:
    echo "too slow"

run main()
```
