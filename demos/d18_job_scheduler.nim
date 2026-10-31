## 18 - Cron-style job scheduler with per-job watchdogs and graceful shutdown.
## Three periodic jobs run concurrently; "slow-sync" hangs on its 3rd run and its
## watchdog (a `select` with a timeout on the job's heartbeat channel) notices.
## An Event stops everything cleanly after 400 ms; every task is joined.
import std/strformat
import stagelane

var runs: array[3, int]

proc periodic(idx: int, every, cost, stallAt: int, stop: Event, beats: Chan[int]) {.flow.} =
  while not stop.isSet:
    delay(every)
    if stop.isSet: break
    inc runs[idx]
    delay(cost)                                # the job's actual work
    if runs[idx] == stallAt: delay(100)        # simulated hang
    discard beats.trySend(runs[idx])
  beats.close()

proc watchdog(name: string, beats: Chan[int], stop: Event): int {.flow.} =
  var lastSeen = 0
  try:
    while true:
      select:
        beats.recv(b): lastSeen = b            # raises ChanClosedError once closed+drained
        timeout(80):
          if not stop.isSet:
            inc result
            echo &"  [watchdog:{name}] no heartbeat for 80 ms (last beat #{lastSeen}) - stuck?"
  except ChanClosedError: discard              # job finished: watchdog retires

proc main() {.flow.} =
  let stop = newEvent()
  var missed = 0
  scope s:
    var dogs: seq[Task[int]]
    let names = ["metrics", "cleanup", "slow-sync"]
    let every = [20, 50, 40]
    let cost = [1, 5, 2]
    for i in 0 .. 2:
      let beats = newChan[int](64)
      discard s.go periodic(i, every[i], cost[i], (if i == 2: 3 else: 0), stop, beats)
      dogs.add s.go watchdog(names[i], beats, stop)
    delay(400)
    stop.set()                                 # graceful shutdown request
    for d in dogs: missed += await(d)
  echo &"runs: metrics={runs[0]} cleanup={runs[1]} slow-sync={runs[2]}; stalls detected: {missed}"
  doAssert missed >= 1

run main()
