import ../src/stagelane
proc w(ms: int): int {.flow.} =
  delay(ms)
  result = 1
proc m1(): int {.flow.} =
  result = w(1)
proc m2(): int {.flow.} =
  let t = go w(5)
  result = await(t)
proc m3(): int {.flow.} =
  let t = go w(5000)
  yieldNow()
  cancel(t)
  waitDone(t)
  result = 1
when defined(a): echo run m1()
when defined(b): echo run m2()
when defined(c): echo run m3()
