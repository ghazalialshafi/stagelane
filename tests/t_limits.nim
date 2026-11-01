import ../src/stagelane
import std/[tables, strutils]

type C = ref object of Frame

proc id(x: int): int {.flow: C.} = x

# --- openArray / varargs: copied in, usable across suspensions -------------
proc sumOA(a: openArray[int]): int {.flow: C.} =
  for x in a: result += id(x)

proc joinVA(sep: string, xs: varargs[string]): string {.flow: C.} =
  for i, x in xs:
    if i > 0: result.add sep
    result.add x
    discard id(0)

# --- var params: allowed on procs that never suspend (native code) ---------
proc bump(x: var int, by: int) {.flow: C.} = x += by
proc fill(s: var seq[int], n: int) {.flow: C.} =
  for i in 0..<n: s.add i
proc viaFlow(): int {.flow: C.} =
  var v = id(1)
  bump(v, 10)
  var s: seq[int]
  fill(s, 3)
  v + s.len + id(100)

# --- pragmas on the proc declaration ---------------------------------------
proc inl(x: int): int {.flow: C, inline.} = x * 2
proc cdec(x: int): int {.flow: C, cdecl.} = id(x) + 1

# --- block pragmas survive lowering ----------------------------------------
var counter {.threadvar.}: int
proc gc(): int {.flow: C.} =
  {.cast(gcsafe).}:
    counter += 1
    discard id(1)
    counter += 1
  result = counter

# --- tuple destructuring in for loops --------------------------------------
proc sid(x: int): int {.flow: C.} =
  delay(0)
  x
proc pureTup(xs: seq[(int, string)]): string {.flow: C.} =
  for (a, b) in xs: result.add b & $id(a)
proc susTup(xs: seq[(int, string)]): string {.flow: C.} =
  for (a, b) in xs: result.add b & $sid(a)
proc susPairs(xs: seq[string]): string {.flow: C.} =
  for (i, x) in xs.pairs: result.add x & $sid(i)
proc susTab(): string {.flow: C.} =
  var t = {1: "a", 2: "b"}.toOrderedTable
  for (k, v) in t.pairs: result.add v & $sid(k)
proc nestedTup(xs: seq[(int, string)]): string {.flow: C.} =
  for (a, b) in xs:
    for c in b: result.add c & $sid(a)

# --- cancel handler that re-raises compiles without warnings -----------------
var cleaned: seq[string]
proc cancellable(): int {.flow: C.} =
  try:
    delay(10_000)
    result = 1
  except CancelledError:
    cleaned.add "cleanup"
    raise
proc cancelMain(): string {.flow: C.} =
  let t = go cancellable()
  delay(5)
  cancel(t)
  waitDone(t)
  result = $t.state & $cleaned

# --- tuple destructuring over mitems mutates in place ------------------------
proc mutTup(): string {.flow: C.} =
  var xs = @[(1, "x"), (2, "y")]
  for (a, b) in mitems(xs):
    a += sid(10)
    b.add "!"
  for (a, b) in xs: result.add b & $a

# --- eachRecv, split close errors, deadlock message ---------------------------
proc producer(ch: Chan[int]) {.flow: C.} =
  for i in 1..3:
    ch.send(i)
    delay(1)
  ch.close()
proc consumer(): int {.flow: C.} =
  let ch = newChan[int](1)
  discard go producer(ch)
  eachRecv(ch, v):
    result += v
proc closedKinds(): string {.flow: C.} =
  let ch = newChan[int](1)
  ch.close()
  try: ch.send(1)
  except SendOnClosedError: result.add "S"
  try: discard ch.recv()
  except RecvOnClosedError: result.add "R"
  try: ch.send(1)
  except ChanClosedError: result.add "B"
proc stuck(): int {.flow: C.} =
  let ch = newChan[int](1)
  result = ch.recv()

var failed = 0
template check(name: string, got, want: untyped) =
  if got == want: echo "ok   ", name
  else:
    echo "FAIL ", name, ": ", got, " != ", want
    failed = 1

check "openArray", sumOA([1, 2, 3]), 6
check "openArray seq", sumOA(@[4, 5]), 9
check "varargs", joinVA(",", "a", "b", "c"), "a,b,c"
var v = 1
bump(v, 4)
check "var direct", v, 5
var q: seq[int]
fill(q, 4)
check "var seq", q.len, 4
check "var from flow", viaFlow(), 114
check "inline", inl(4), 8
check "cdecl", cdec(4), 5
check "block pragma", gc(), 2
check "tuple pure", pureTup(@[(1, "x"), (2, "y")]), "x1y2"
check "tuple suspending", run susTup(@[(1, "x"), (2, "y")]), "x1y2"
check "tuple pairs", run susPairs(@["p", "q"]), "p0q1"
check "tuple table", run susTab(), "a1b2"
check "tuple nested", run nestedTup(@[(1, "xy"), (2, "z")]), "x1y1z2"
check "cancel re-raise", run cancelMain(), "tsCancelled@[\"cleanup\"]"
check "tuple mitems", run mutTup(), "x!11y!12"
check "eachRecv", run consumer(), 6
check "closed kinds", run closedKinds(), "SRB"
var msg = ""
try: discard run stuck()
except DeadlockError as e: msg = e.msg
check "deadlock detail", ("parked on" in msg) and ("blocked" in msg), true
quit failed
