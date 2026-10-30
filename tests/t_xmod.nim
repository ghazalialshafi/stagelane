## flow procs used across module boundaries
import ../src/stagelane
import xmod_lib

# purity must be visible to importers
static:
  doAssert neverSuspends(fib(5))
  doAssert neverSuspends(viaHelper(1))
  doAssert not neverSuspends(slowDouble(1))
  doAssert not neverSuspends(fetch("x"))
  doAssert not neverSuspends(deep(1))          # `heap`: always a real frame

proc main(): string {.flow.} =
  # go / await on an imported proc
  let t = go fetch("a")
  let u = go slowDouble(21)
  result = await(t) & "," & $await(u)
  # direct calls from a flow proc
  result &= "," & fetch("b") & "," & $slowDouble(4)
  result &= "," & $fib(20) & "," & $viaHelper(1)
  # structured scope + imported procs
  var total = 0
  scope s:
    let a = s.go slowDouble(1)
    let b = s.go slowDouble(2)
    total = 0
  result &= "," & $deep(50_000)

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check run main(), "got a,42,got b,8,6765,102,50000"
# imported procs are ordinary procs outside any flow, too
check fib(15), 610
check fetch("c"), "got c"
check viaHelper(2), 103
# prepare: a frame that has not run yet
check blockOn(prepare(slowDouble(5)), int), 10

# a flow proc called from ordinary code behaves like an ordinary function:
# a proc that never suspends allocates nothing and needs no event loop
block:
  let before = getOccupiedMem()
  var acc = 0
  for i in 0..<100_000: acc += fib(5)
  doAssert acc == 500_000
  doAssert getOccupiedMem() - before < 4096, "pure flow proc allocated"
  echo "ok   pure flow proc called from plain code: no allocation"
