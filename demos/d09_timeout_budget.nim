## 09 - Deadline propagation: a request has a 100 ms budget shared by 3 stages.
## Slow requests are abandoned precisely at their deadline; fast ones succeed.
import std/[strformat]
import stagelane

proc auth(ms: int) {.flow.} = delay(ms)
proc loadData(ms: int): int {.flow.} = delay(ms); ms * 2
proc render(ms: int) {.flow.} = delay(ms)

proc handler(a, b, c: int): int {.flow.} =
  auth(a); result = loadData(b); render(c)

proc serve(id, a, b, c: int): string {.flow.} =
  try:
    let v = withTimeout(100, handler(a, b, c))
    &"req {id}: OK ({v})"
  except TimeoutError:
    &"req {id}: DEADLINE EXCEEDED ({a}+{b}+{c} = {a + b + c} ms > 100)"

proc main() {.flow.} =
  scope s:
    var rs: seq[Task[string]]
    rs.add s.go serve(1, 10, 20, 10)
    rs.add s.go serve(2, 30, 40, 20)
    rs.add s.go serve(3, 20, 80, 30)
    rs.add s.go serve(4, 5, 5, 5)
    rs.add s.go serve(5, 50, 50, 50)
    for r in rs: echo await(r)

run main()
