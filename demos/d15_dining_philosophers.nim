## 15 - Dining philosophers. The naive "left fork then right fork" strategy
## deadlocks; stagelane's runtime DETECTS it (DeadlockError) instead of hanging.
## The fix - always take the lower-numbered fork first - lets all 5 philosophers
## eat 40 meals each, and we verify no two neighbours ever ate simultaneously.
import std/strformat
import stagelane

const N = 5
var eating: array[N, bool]
var violations = 0
var meals: array[N, int]

proc philosopher(i: int, forks: seq[Mutex], ordered: bool, rounds: int) {.flow.} =
  let left = i
  let right = (i + 1) mod N
  let first = if ordered: min(left, right) else: left
  let second = if ordered: max(left, right) else: right
  for _ in 1..rounds:
    delay(1)                                # think
    withLock(forks[first]):
      yieldNow()                            # everybody grabs their first fork...
      withLock(forks[second]):              # ...then waits for the second
        if eating[(i + 1) mod N] or eating[(i + N - 1) mod N]: inc violations
        eating[i] = true
        delay(2)                            # eat
        eating[i] = false
        inc meals[i]

proc table(ordered: bool, rounds: int) {.flow.} =
  var forks: seq[Mutex]
  for _ in 1..N: forks.add newMutex()
  scope s:
    for i in 0 ..< N: discard s.go philosopher(i, forks, ordered, rounds)

proc fixed() {.flow.} =
  table(ordered = true, rounds = 40)

# The deadlock is reported by the event loop itself, so catch it around `run`.
try:
  run table(ordered = false, rounds = 40)
  echo "naive   : finished (lucky!)"
except DeadlockError:
  echo "naive   : DeadlockError - all 5 hold one fork and wait for the next; runtime noticed"

meals = default(array[N, int])
run fixed()
echo &"ordered : meals per philosopher {meals}, neighbour violations: {violations}"
doAssert violations == 0 and meals == [40, 40, 40, 40, 40]
