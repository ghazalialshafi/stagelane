import ../src/stagelane

# --- pure (never suspends) procs compile to native code --------------------------
proc fib(n: int): int {.flow.} =
  if n < 2: return n
  result = fib(n-1) + fib(n-2)

proc sumTo(n: int): int {.flow.} =
  for i in 1..n: result += i

proc failing(x: int): int {.flow.} =
  if x > 3: raise newException(ValueError, "too big")
  x

# a proc that reaches a suspension primitive is *not* pure, transitively
proc napper(): int {.flow.} =
  yieldNow()
  1
proc usesNapper(): int {.flow.} = napper() + 1
proc usesPure(): int {.flow.} = fib(10) + sumTo(10)

# heap: forced onto the heap, so unbounded recursion depth is fine
proc deep(n: int): int {.flow, heap.} =
  if n == 0: return 0
  result = deep(n - 1) + 1

proc deepDriver(n: int): int {.flow.} =
  result = deep(n)

proc main(): string {.flow.} =
  var parts: seq[string]
  parts.add $fib(20)
  parts.add $usesPure()
  parts.add $usesNapper()
  parts.add $deep(200_000)               # would overflow the C stack if native
  try: discard failing(9)
  except ValueError as e: parts.add e.msg
  let t = go fib(15)                  # pure procs can still be spawned as tasks
  parts.add $await(t)
  for p in parts: result &= p & ";"

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check run main(), "6765;110;2;200000;too big;610;"
# pure procs also work as plain procs, outside of any event loop
check fib(12), 144
check sumTo(100), 5050
check run deepDriver(100_000), 100_000
# hygiene: user names that clash with identifiers used by generated code
proc hygiene(): int {.flow.} =
  var sink = 1
  var move = 2
  var len = 3
  var reset = 4
  yieldNow()
  result = sink + move + len + reset
check run hygiene(), 10
