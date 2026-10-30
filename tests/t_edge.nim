import ../src/stagelane
import std/[strutils, tables, options]

type
  C = ref object of Frame
  Pt = object
    x, y: int
  Shape = ref object of RootObj
    name: string

var log: seq[string]

proc id(x: int): int {.flow: C.} = x
proc ids(x: string): string {.flow: C.} = x
proc pair(a, b: int): (int, string) {.flow: C.} = (a, $b)
proc mk(a: int): Pt {.flow: C.} = Pt(x: a, y: a * 2)
proc nop() {.flow: C.} = discard
proc thrower(msg: string) {.flow: C.} = raise newException(ValueError, msg)
proc maybe(x: int): Option[int] {.flow: C.} =
  if x > 0: some(x) else: none(int)

# jumps through finally blocks
proc finJumps(): string {.flow: C.} =
  for i in 0..4:
    try:
      if id(i) == 1: continue
      if id(i) == 3: break
      result &= $i
    finally:
      result &= "f"
  result &= "!"

proc nestedFinally(): string {.flow: C.} =
  try:
    try:
      nop()
      return "ret"
    finally:
      log.add "in"
  finally:
    log.add "out"

proc finRaises(): string {.flow: C.} =
  try:
    try:
      thrower("a")
    finally:
      log.add "cleanup"
  except ValueError as e:
    result = e.msg

# exception thrown inside a handler / finally
proc handlerThrows(): string {.flow: C.} =
  try:
    try:
      thrower("first")
    except ValueError:
      nop()
      thrower("second")
  except ValueError as e:
    result = e.msg

proc catchAll(): string {.flow: C.} =
  try:
    thrower("x")
  except:
    result = "any " & getCurrentExceptionMsg()

proc multiTypes(k: int): string {.flow: C.} =
  try:
    if id(k) == 0: thrower("v")
    elif id(k) == 1: raise newException(KeyError, "k")
    else: raise newException(IOError, "io")
  except ValueError, KeyError:
    result = "vk"
  except IOError as e:
    result = "io:" & e.msg

# data flow
proc tuples(): string {.flow: C.} =
  let (a, b) = pair(id(3), id(4))
  var (c, d) = pair(5, 6)
  c += a
  result = $a & b & $c & d

proc objects(): int {.flow: C.} =
  let p = mk(id(5))
  let q = Pt(x: id(1), y: mk(7).y)
  result = p.x + p.y + q.x + q.y

proc strings(): string {.flow: C.} =
  result = ids("a") & ids("b") & $id(3) & "-" & ids("z")
  result &= (if id(1) == 1: ids("T") else: ids("F"))

proc seqs(): seq[int] {.flow: C.} =
  result = @[id(1), id(2), id(3)]
  result.add id(4) + id(5)
  result[0] = id(9)

proc condLoop(): int {.flow: C.} =
  var n = 0
  while id(n) < 5:
    n += id(2)
  for i in 0..<id(3): n += 100
  result = n

proc caseStr(s: string): int {.flow: C.} =
  case ids(s)
  of "a": result = id(1)
  of "b", "c": result = id(2)
  else: result = id(3)

proc caseExpr(x: int): string {.flow: C.} =
  result = case id(x)
    of 1: ids("one")
    of 2: "two"
    else: ids("many")

proc ifExpr(x: int): int {.flow: C.} =
  let v = if id(x) > 0: id(10) elif id(x) == 0: 0 else: id(-10)
  result = v + 1

proc blockExpr(): int {.flow: C.} =
  let v = block:
    let a = id(2)
    a * id(3)
  result = v

proc tryExpr(x: int): int {.flow: C.} =
  result = try: id(x) + 1
           except ValueError: -1
  let w = try:
    thrower("w")
    0
  except ValueError: id(42)
  result += w

proc discards(): int {.flow: C.} =
  discard id(1)
  discard maybe(2)
  result = id(7)

proc recursiveTree(d: int): int {.flow: C.} =
  if d == 0: return 1
  result = recursiveTree(d - 1) + recursiveTree(d - 1)

proc manyLocals(): string {.flow: C.} =
  var a = 1
  var s = "x"
  var arr: array[3, int]
  var t = initTable[string, int]()
  for i in 0..2:
    arr[i] = id(i * i)
    t[$i] = arr[i]
    s &= $id(i)
  result = s & $arr & $t["2"] & $a

proc verbatimMix(): int {.flow: C.} =
  # code without suspension points between suspension points
  var total = 0
  for i in 1..10:
    total += i * i
  let m = id(total)
  var local = newSeq[int]()
  for j in 0..<m mod 7: local.add j
  result = m + local.len
  block done:
    for k in 0..3:
      if k == 2: break done
      result += 1

proc defers(): string {.flow: C.} =
  defer: result &= "D1"
  block:
    defer: result &= "D2"
    result &= ids("a")
  result &= ids("b")

proc shadow(): int {.flow: C.} =
  var x = id(1)
  block:
    var x = id(100)
    x += 1
    result += x
  result += x

proc whileBreakFinally(): string {.flow: C.} =
  var i = 0
  while true:
    try:
      inc i
      if id(i) == 3: break
    finally:
      result &= "f"
  result &= $i

proc labelled(): string {.flow: C.} =
  block a:
    block b:
      result &= "1"
      if id(1) == 1: break a
      result &= "2"
    result &= "3"
  result &= "4"

proc earlyReturnVoid() {.flow: C.} =
  log.add "a"
  if id(1) == 1: return
  log.add "b"

# lvalues passed by `var` are never copied into temporaries
type Acc = object
  total: int
  names: seq[string]
  grid: array[3, int]

proc varOperands(): string {.flow.} =
  var a: Acc
  var tab = {"k": 1}.toTable
  var xs = @[10, 20]
  var n = 0
  a.total += id(5)
  a.grid[1] += id(7)
  a.names.add ids("x")
  a.names.add ids("y") & ids("z")
  tab["k"] += id(41)
  xs[0] += id(1) + id(2)
  inc(n, id(3))
  n *= id(2)
  result = $a.total & $a.grid & $a.names & $tab["k"] & $xs & $n

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check finJumps(), "0ff2ff!"
check nestedFinally(), "ret"
check log.join(","), "in,out"
log.setLen 0
check finRaises(), "a"
check log.join(","), "cleanup"
check handlerThrows(), "second"
check catchAll(), "any x"
check multiTypes(0), "vk"
check multiTypes(1), "vk"
check multiTypes(2), "io:io"
check tuples(), "34" & "8" & "6"
check objects(), 30
check strings(), "ab3-zT"
check seqs(), @[9, 2, 3, 9]
check condLoop(), 306
check caseStr("a"), 1
check caseStr("c"), 2
check caseStr("q"), 3
check caseExpr(1), "one"
check caseExpr(2), "two"
check caseExpr(5), "many"
check ifExpr(1), 11
check ifExpr(0), 1
check ifExpr(-1), -9
check blockExpr(), 6
check tryExpr(1), 44
check discards(), 7
check recursiveTree(10), 1024
check manyLocals(), "x012" & "[0, 1, 4]" & "4" & "1"
check verbatimMix(), 387
check defers(), "aD2bD1"
check shadow(), 102
check whileBreakFinally(), "fff3"
check labelled(), "14"
log.setLen 0
earlyReturnVoid()
check log.join(","), "a"
check varOperands(), "5[0, 7, 0]@[\"x\", \"yz\"]42@[13, 20]6"
