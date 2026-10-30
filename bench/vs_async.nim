import std/[asyncdispatch, monotimes, times, strutils]
proc leaf(x: int): Future[int] {.async.} =
  return x + 1
proc caller(n: int): Future[int] {.async.} =
  for i in 0..<n: result += await leaf(i)
proc child(x: int): Future[int] {.async.} =
  await sleepAsync(0)
  return x
proc spawner(n: int): Future[int] {.async.} =
  for i in 0..<n:
    let f = child(i)
    result += await f
template timeit(name: string, ops: int, body: untyped) =
  let t0 = getMonoTime()
  body
  let ns = (getMonoTime() - t0).inNanoseconds
  echo name.alignLeft(34), formatFloat(ns.float/1e6, ffDecimal, 1).align(8), " ms ",
       formatFloat(ns.float/ops.float, ffDecimal, 1).align(8), " ns/op"
timeit "async call (1M)", 1_000_000: discard waitFor caller(1_000_000)
timeit "async go+await+delay(0) (200k)", 200_000: discard waitFor spawner(200_000)
