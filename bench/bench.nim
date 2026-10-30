import ../src/stagelane
import std/[monotimes, times, strutils]

var sink: int

# impure leaf: contains a suspension point on a cold path, so it stays a real continuation
proc leaf(x: int): int {.flow.} =
  if x < 0: yieldNow()
  result = x + 1

proc caller(n: int): int {.flow.} =
  for i in 0..<n: result += leaf(i)

proc depth(n: int): int {.flow.} =       # deep non-tail recursion, impure
  if n == 0:
    yieldNow()
    return 0
  result = depth(n - 1) + 1

proc yielder(n: int) {.flow.} =
  for i in 0..<n: yieldNow()

proc child(x: int): int {.flow.} =
  yieldNow()
  x

proc spawner(n: int): int {.flow.} =
  for i in 0..<n:
    let t = go child(i)
    result += await(t)

proc pinger(a, b: Chan[int], n: int) {.flow.} =
  for i in 0..<n:
    a.send(i)
    discard b.recv()
proc ponger(a, b: Chan[int], n: int) {.flow.} =
  for i in 0..<n: b.send(a.recv() + 1)
proc pingpong(n: int): int {.flow.} =
  let a = newChan[int](1)
  let b = newChan[int](1)
  let p = go pinger(a, b, n)
  let q = go ponger(a, b, n)
  await(p); await(q)
  n

proc sleeper(ms: int) {.flow.} = delay(ms)
proc manySleepers(n: int) {.flow.} =
  scope g:
    for i in 0..<n: discard go(g, sleeper(1 + i mod 5))

proc fanout(n: int): int {.flow.} =
  scope g:
    for i in 0..<n: discard go(g, yielder(3))
  n

template timeit(name: string, ops: int, body: untyped) =
  let t0 = getMonoTime()
  body
  let ns = (getMonoTime() - t0).inNanoseconds
  echo name.alignLeft(34), formatFloat(ns.float/1e6, ffDecimal, 1).align(8), " ms ",
       formatFloat(ns.float/ops.float, ffDecimal, 1).align(8), " ns/op ",
       formatFloat(ops.float*1e3/ns.float, ffDecimal, 2).align(8), " M op/s"

sink += run caller(100)           # warm up
timeit "impure flow call (10M)", 10_000_000: sink += run caller(10_000_000)
timeit "deep recursion d=10k x 100", 1_000_000: (for _ in 0..<100: sink += run depth(10_000))
timeit "yieldNow switch (5M)", 5_000_000: run yielder(5_000_000)
timeit "go+await+1 yield (500k)", 500_000: sink += run spawner(500_000)
timeit "100k tasks x 3 yields", 400_000: sink += run fanout(100_000)
timeit "chan ping-pong (500k rounds)", 1_000_000: sink += run pingpong(500_000)
timeit "100k timers", 100_000: run manySleepers(100_000)
echo sink
