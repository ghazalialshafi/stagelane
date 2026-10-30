import ../src/stagelane
import std/times

proc worker(id, ms: int): int {.flow.} =
  delay(ms)
  result = id * 10

proc main(): int {.flow.} =
  let a = go worker(1, 30)
  let b = go worker(2, 10)
  let c = go worker(3, 20)
  result = await(a) + await(b) + await(c)

echo run main()

proc failing(): int {.flow.} =
  delay(5)
  raise newException(ValueError, "nope")

proc cancelMe(): string {.flow.} =
  try:
    delay(10_000)
    result = "finished"
  except CancelledError:
    result = "cancelled"

proc main2(): string {.flow.} =
  let t = go failing()
  try:
    discard await(t)
  except ValueError as e:
    result = "caught " & e.msg
  let k = go cancelMe()
  yieldNow()
  cancel(k)
  result &= " / " & await(k)

echo run main2()

proc main3(): string {.flow.} =
  var log = ""
  try:
    scope g:
      discard go(g, worker(1, 5))
      discard go(g, failing())
      discard go(g, cancelMe())
  except ValueError as e:
    log = "group failed: " & e.msg
  result = log

echo run main3()

proc main4(): string {.flow.} =
  try:
    let v = withTimeout(20, worker(5, 1000))
    result = $v
  except TimeoutError:
    result = "timeout"
  result &= " " & $withTimeout(200, worker(6, 5))

let t0 = epochTime()
echo run main4()
echo "elapsed ok: ", epochTime() - t0 < 0.5
