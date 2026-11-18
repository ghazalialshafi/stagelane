# Flow procs as values (`FlowFn`): call, go, scope.go, bound arguments, tables of handlers,
# exceptions, cancellation, and that nothing leaks or double-frees.
import ../src/stagelane
import std/tables

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

type
  Boom = object of CatchableError
  Op = FlowFn[proc (x: int): int]
  Job = FlowFn[proc ()]

var ran = 0
var cleaned = 0

proc twice(x: int): int {.flow.} = yieldNow(); x * 2
proc addN(n, x: int): int {.flow.} = delay(1); x + n
proc pureInc(x: int): int {.flow.} = x + 1
proc boom(x: int): int {.flow.} =
  yieldNow()
  if x > 2: raise newException(Boom, "x=" & $x)
  x
proc bump() {.flow.} = delay(1); inc ran
proc sleepy(x: int): int {.flow.} =
  try: delay(10_000); x
  finally: inc cleaned
proc concat3(a: string, b: string, c: string): string {.flow.} =
  yieldNow(); a & b & c

proc applyAll(ops: seq[Op], x: int): int {.flow.} =
  result = x
  for o in ops: result = o.call(result)

proc viaParam(o: Op): int {.flow.} = o.call(5) + 1

proc t1(): int {.flow.} =
  # a pipeline of stored stages, bound and unbound, pausing and pure
  let ops = @[flowFn(twice), flowFn(addN, 3), flowFn(pureInc), flowFn(twice)]
  applyAll(ops, 4)                      # ((4*2)+3+1)*2 = 24
check run t1(), 24

proc t2(): string {.flow.} =
  var table = initTable[string, Op]()
  table["double"] = flowFn(twice)
  table["plus10"] = flowFn(addN, 10)
  result = $table["double"].call(21) & "," & $table["plus10"].call(1) & "," & $viaParam(table["double"])
check run t2(), "42,11,11"

proc t3(): int {.flow.} =
  # as tasks: go, scope.go, withTimeout-free await
  let f = flowFn(addN, 100)
  let a = go f.call(1)
  var s = 0
  scope g:
    var hs: seq[Task[int]]
    for i in 0..<10: hs.add g.go f.call(i)
    for h in hs: s += await(h)
  s + await(a)                           # (100*10 + 45) + 101
check run t3(), 1146

proc t4(): string {.flow.} =
  # an exception travels through the value call like through a direct call
  let f = flowFn(boom)
  try:
    discard f.call(1)
    discard f.call(7)
    "no raise"
  except Boom as e: "caught " & e.msg
check run t4(), "caught x=7"

proc t5(): string {.flow.} =
  # exceptions through a task, and cancellation of a task running a value
  let f = flowFn(boom)
  let t = go f.call(9)
  try: discard await(t); result = "none"
  except Boom: result = "task failed;"
  let s = go flowFn(sleepy).call(1)
  delay(2)
  s.cancel()
  try: discard await(s)
  except CancelledError: result &= "cancelled;"
  result &= $cleaned
check run t5(), "task failed;cancelled;1"

proc t6(): string {.flow.} =
  # void procs and several bound arguments; strings are owned by the closure box
  let j: Job = flowFn(bump)
  j.call(); j.call()
  let c = flowFn(concat3, "a", "b")
  result = c.call("c") & $ran
  let c2 = c                              # copies share the bound state: still valid
  result &= c2.call("d")
check run t6(), "abc2abd"

proc t7(): int {.flow.} =
  # pooled frames of the target proc keep being reused correctly through values
  let f = flowFn(addN, 1)
  for i in 0..<2000: result += f.call(i)
check run t7(), 2000 * 1999 div 2 + 2000

# outside a flow proc the call blocks, like calling the proc directly
check flowFn(twice).call(8), 16
check flowFn(concat3, "x").call("y", "z"), "xyz"
echo "all ok"
