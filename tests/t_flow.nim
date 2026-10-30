import ../src/stagelane
import std/[strutils, tables]

type C = ref object of Frame

var log: seq[string]

proc id(x: int): int {.flow: C.} = x
proc ids(x: string): string {.flow: C.} = x
proc boom(x: int): int {.flow: C.} =
  if x > 2: raise newException(ValueError, "boom " & $x)
  result = x
proc nop() {.flow: C.} = log.add "nop"

proc fib(n: int): int {.flow: C.} =
  if n < 2: return n
  result = fib(n-1) + fib(n-2)

proc branches(x: int): string {.flow: C.} =
  if id(x) == 1: result = "one"
  elif id(x) == 2: result = "two"
  else: result = "many" & ids($x)

proc cases(x: int): string {.flow: C.} =
  case id(x)
  of 1: result = "a"
  of 2, 3: result = ids("b")
  else: result = "c"

proc loops(): seq[int] {.flow: C.} =
  for i in 0..3:
    if i == 1: continue
    result.add id(i)
  for i in 0..<3:
    result.add id(i) * 10
  var j = 0
  while true:
    inc j
    if id(j) > 3: break
    result.add 100 + j

proc coll(): string {.flow: C.} =
  let s = @["x", "y", "z"]
  for it in s: result.add ids(it)
  for i, it in s: result.add $i & ids(it)
  var m = @[1,2]
  for it in mitems(m): it = id(it) + 1
  result.add $m

proc tab(): int {.flow: C.} =
  var t = {"a": 1, "b": 2}.toTable
  for k, v in t:
    result += id(v)

proc blocks(): int {.flow: C.} =
  block outer:
    for i in 0..5:
      for j in 0..5:
        if id(i * j) == 6: result = i*10+j; break outer

proc tries(x: int): string {.flow: C.} =
  try:
    let v = boom(x)
    result = "ok" & $v
  except ValueError as e:
    result = "caught " & e.msg
  finally:
    log.add "fin" & $x

proc nested(x: int): string {.flow: C.} =
  try:
    try:
      discard boom(x)
    finally:
      log.add "inner"
    result = "no"
  except CatchableError:
    result = "outer " & getCurrentExceptionMsg()

proc retInTry(): int {.flow: C.} =
  for i in 0..9:
    try:
      if id(i) == 3: return i
    finally:
      log.add "f" & $i

proc deferred(): int {.flow: C.} =
  defer: log.add "deferred"
  nop()
  result = 5

proc exprs(a: int): bool {.flow: C.} =
  result = id(a) > 1 and id(a) < 5 or id(a) == 100

proc nestedCalls(): int {.flow: C.} =
  result = id(id(1) + id(2)) * (if id(1) == 1: id(10) else: 0)

proc rethrow(x: int): string {.flow: C.} =
  try:
    try:
      discard boom(x)
    except ValueError:
      nop()
      raise
  except ValueError as e:
    result = "re " & e.msg

proc uncaught(): int {.flow: C.} =
  result = boom(10)

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check fib(15), 610
check branches(1), "one"
check branches(2), "two"
check branches(7), "many7"
check cases(1), "a"
check cases(3), "b"
check cases(9), "c"
check loops(), @[0,2,3,0,10,20,101,102,103]
check coll(), "xyz0x1y2z@[2, 3]"
check tab(), 3
check blocks(), 23
check tries(1), "ok1"
check tries(5), "caught boom 5"
check log.join(","), "fin1,fin5"
log.setLen 0
check nested(5), "outer boom 5"
check log.join(","), "inner"
log.setLen 0
check retInTry(), 3
check log.join(","), "f0,f1,f2,f3"
log.setLen 0
check deferred(), 5
check log.join(","), "nop,deferred"
check exprs(3), true
check exprs(7), false
check exprs(100), true
check nestedCalls(), 30
check rethrow(7), "re boom 7"
try:
  discard uncaught()
  echo "FAIL no exception"; quit 1
except ValueError as e:
  echo "ok   uncaught propagates: ", e.msg
