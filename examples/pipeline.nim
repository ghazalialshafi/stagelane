## fan-out / fan-in with channels and select
import ../src/stagelane

proc gen(ch: Chan[int], n: int) {.flow.} =
  for i in 1..n: ch.send(i)
  ch.close()

proc square(inp, outp: Chan[int]) {.flow.} =
  while true:
    let v = inp.recvOpt()
    if v.isNone: break
    outp.send(v.get * v.get)

proc collect(ch: Chan[int], total: int): int {.flow.} =
  for _ in 1..total: result += ch.recv()

proc main(): int {.flow.} =
  let a = newChan[int](8)
  let b = newChan[int](8)
  discard go gen(a, 100)
  for _ in 1..4: discard go square(a, b)   # 4 workers share one input
  result = collect(b, 100)

echo run main()          # 338350
