import ../src/stagelane
import std/[monotimes, times]

proc work(n: int): int {.flow.} =
  yieldNow()                      # makes the proc impure (a real continuation)
  var sum = 0
  for i in 0..<n: sum += i xor (i shr 3)     # suspension-free loop
  var j = 0
  while j < n:                                # ...and a while loop
    sum += j and 7
    inc j
  yieldNow()
  sum

let t0 = getMonoTime()
let r = run work(400_000_000)
let ns = (getMonoTime() - t0).inNanoseconds
echo r, "  ", ns div 1_000_000, " ms for 800M loop iterations  (", ns.float / 800e6, " ns/iter)"
