## 16 - Race conditions are still possible with cooperative tasks whenever a task
## PAUSES between read and write. 2,000 concurrent transfers between 10 accounts:
##   unsafe : read balance, pause (audit-log I/O), write balance -> money appears/vanishes
##   safe   : per-account Mutex, locked in index order            -> total preserved exactly
import std/[random, strformat]
import stagelane

const Accounts = 10
const Start = 1000
var bal: array[Accounts, int]

proc unsafeTransfer(a, b, amt: int) {.flow.} =
  let fromBal = bal[a]
  let toBal = bal[b]
  delay(1)                                   # audit log write: other tasks run here!
  bal[a] = fromBal - amt
  bal[b] = toBal + amt

proc safeTransfer(locks: seq[Mutex], a, b, amt: int) {.flow.} =
  let (lo, hi) = (min(a, b), max(a, b))      # global lock order -> no deadlock
  withLock(locks[lo]):
    withLock(locks[hi]):
      let fromBal = bal[a]
      let toBal = bal[b]
      delay(1)
      bal[a] = fromBal - amt
      bal[b] = toBal + amt

proc total(): int =
  for x in bal: result += x

proc runAll(safe: bool): int {.flow.} =
  for i in 0 ..< Accounts: bal[i] = Start
  var locks: seq[Mutex]
  for _ in 1..Accounts: locks.add newMutex()
  var r = initRand(7)
  scope s:
    for _ in 1..2000:
      let a = r.rand(Accounts - 1)
      var b = r.rand(Accounts - 1)
      if b == a: b = (a + 1) mod Accounts
      let amt = 1 + r.rand(50)
      if safe: discard s.go safeTransfer(locks, a, b, amt)
      else: discard s.go unsafeTransfer(a, b, amt)
  total()

proc main() {.flow.} =
  let expected = Accounts * Start
  let u = runAll(false)
  echo &"unsafe : total = {u}  (expected {expected}, drift {u - expected})"
  let sf = runAll(true)
  echo &"safe   : total = {sf}  (expected {expected}, drift {sf - expected})"
  doAssert sf == expected

run main()
