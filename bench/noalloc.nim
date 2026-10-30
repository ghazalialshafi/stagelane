import ../src/stagelane
# a 3-stage pipeline moving 1M ints: after warm-up nothing may be allocated
proc stage(inp, outp: Chan[int], n: int) {.flow.} =
  for _ in 0..<n: outp.send(inp.recv() + 1)
proc source(outp: Chan[int], n: int) {.flow.} =
  for i in 0..<n: outp.send(i)
proc sink(inp: Chan[int], n: int): int {.flow.} =
  for _ in 0..<n: result += inp.recv()
proc run1(n: int): int {.flow.} =
  let a = newChan[int](16)
  let b = newChan[int](16)
  let c = newChan[int](16)
  discard go source(a, n)
  discard go stage(a, b, n)
  discard go stage(b, c, n)
  result = sink(c, n)
discard run run1(1000)                      # warm-up (fills pools / buffers)
let before = getOccupiedMem()
let r = run run1(1_000_000)
echo "sum ", r, "  occupied-mem delta after 1M msgs x 3 hops: ", getOccupiedMem() - before, " bytes"
