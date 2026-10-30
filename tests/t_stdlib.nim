## The whole Nim standard library is usable inside flow procs: calls that are
## not flow procs are copied through verbatim (no wrapping, no ceremony).
import ../src/stagelane
import std/[json, strutils, sequtils, tables, algorithm, math, sets, options]

type Item = object
  name: string
  qty: int

proc process(raw: string): string {.flow.} =
  # stdlib before the first suspension...
  let doc = parseJson(raw)
  var items: seq[Item]
  for n in doc["items"]:
    items.add Item(name: n["name"].getStr, qty: n["qty"].getInt)
  delay(1)                                   # ...a suspension point...
  # ...and after it: closures, sorting, tables, math, strutils
  items.sort(proc (a, b: Item): int = cmp(b.qty, a.qty))
  var byFirst = initTable[char, int]()
  for it in items: byFirst.mgetOrPut(it.name[0], 0) += it.qty
  let top = items.mapIt(it.name & "=" & $it.qty).join(",")
  let root = sqrt(float(items.foldl(a + b.qty, 0)))
  yieldNow()
  let words = "a,b;c d".split({',', ';', ' '})
  var seen = initHashSet[string]()
  for w in words: seen.incl w
  result = top & "|" & $byFirst['a'] & "|" & root.formatFloat(ffDecimal, 2) &
           "|" & $words.len & "|" & $seen.len & "|" & $(some(3).get + 1)

proc strider(): int {.flow.} =
  var n = 0
  for ch in "12 34 5".split(' '):
    n += parseInt(ch)
    delay(0)
  n

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

check run process("""{"items":[{"name":"apple","qty":3},{"name":"avocado","qty":9},{"name":"fig","qty":4}]}"""),
      "avocado=9,fig=4,apple=3|12|4.00|4|4|4"
check run strider(), 51

# closures that capture locals which live across suspensions
proc capture(): string {.flow.} =
  var offset = 10                       # lifted into the environment
  var xs = @[3, 1, 2]
  delay(1)
  xs.sort(proc (a, b: int): int = cmp((a + offset) mod 7, (b + offset) mod 7))
  let add = proc (x: int): int = x + offset     # closure that escapes the statement
  offset = 100
  delay(1)
  $xs & ":" & $add(1)                   # sees the *current* offset (shared variable)

check run capture(), "@[1, 2, 3]:101"
