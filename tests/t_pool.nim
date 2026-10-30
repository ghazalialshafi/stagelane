import ../src/stagelane
import std/strutils

# Environments are recycled between calls.  None of the state of a previous
# call may be observable in the next one.

proc fresh(i: int): string {.flow.} =
  var s: string               # must start empty every call
  var xs: seq[int]            # ... and so must this
  var n: int                  # ... and this
  var flag: bool
  yieldNow()
  if s.len != 0 or xs.len != 0 or n != 0 or flag: return "STALE"
  s = "call" & $i
  xs.add i
  n = i
  flag = true
  yieldNow()
  s & ":" & $xs & ":" & $n

proc condResult(i: int): int {.flow.} =
  yieldNow()
  if i mod 2 == 0: result = 100 + i      # odd calls must see result == 0

proc raising(i: int): int {.flow.} =
  var s = "dirty" & $i
  yieldNow()
  if i mod 3 == 0: raise newException(ValueError, s)
  s.len

proc nested(d: int): int {.flow.} =
  var acc = d
  yieldNow()
  if d > 0: acc += nested(d - 1)
  acc

proc sleepy(i: int): string {.flow.} =
  var tag = "t" & $i
  try:
    delay(10_000)
    result = "slept"
  except CancelledError:
    result = tag & " cancelled"

proc main(): string {.flow.} =
  var bad = 0
  for i in 0..999:
    let r = fresh(i)
    if r != "call" & $i & ":@[" & $i & "]:" & $i: inc bad
  var oddOk = 0
  for i in 0..99:
    let r = condResult(i)
    if r == (if i mod 2 == 0: 100 + i else: 0): inc oddOk
  var caught = 0
  var fine = 0
  for i in 0..299:
    try:
      let r = raising(i)
      if r == ("dirty" & $i).len: inc fine
    except ValueError as e:
      if e.msg == "dirty" & $i: inc caught
  let deep = nested(500)
  # pooled procs under cancellation, many times
  var cancelled = 0
  for i in 0..49:
    let t = go sleepy(i)
    yieldNow()
    cancel(t)
    if await(t) == "t" & $i & " cancelled": inc cancelled
  result = [$bad, $oddOk, $caught, $fine, $deep, $cancelled].join(",")

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check run main(), "0,100,100,200," & $(500 * 501 div 2) & ",50"
