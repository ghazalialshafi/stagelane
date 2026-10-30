import ../src/stagelane
import ../src/stagelane/exec
import std/[os, times, strutils]

proc work(id, n: int): int {.flow.} =
  for i in 0..<n:
    result += i
    if i mod 10 == 0: yieldNow()
  delay(5)

proc producer(ch: SharedChan[int], n: int) {.flow.} =
  for i in 1..n: ch.send(i)

proc consumer(ch: SharedChan[int], n: int): int {.flow.} =
  for i in 1..n: result += ch.recv()

proc sleeper(): string {.flow.} =
  try:
    delay(10_000)
    result = "slept"
  except CancelledError:
    result = "cancelled"

proc coordinator(ex: Pool): int {.flow.} =
  # fan out over the workers and join from the main scheduler
  var ts: seq[Task[int]]
  for i in 0..<8: ts.add ex.go work(i, 100)
  for t in ts: result += await(t)

let ex = newPool(3)
let main = go coordinator(ex)
let sum = runTask(main)
doAssert sum == 39600
echo "sum: ", sum

let ch = newSharedChan[int](4)
let p1 = ex.go producer(ch, 500)
let p2 = ex.go producer(ch, 500)
let c1 = ex.go consumer(ch, 1000)
let tot = runTask(c1)
doAssert tot == 250500, $tot
echo "chan total: ", tot
runTask(p1); runTask(p2)

let s = ex.go sleeper()
cancel(s)                  # cancel across threads
doAssert runTask(s) == "cancelled"

# --- offloading blocking code --------------------------------------------------
# A plain blocking proc is wrapped in a tiny flow proc; `pool.go` runs it on a
# worker thread while this thread's event loop keeps serving other tasks.
proc blockingQuery(ms: int, tag: string): string =
  os.sleep(ms)                       # blocks the *OS thread*
  tag & ":done"

proc query(ms: int, tag: string): string {.flow.} =
  blockingQuery(ms, tag)

proc ticker(n: int): int {.flow.} =  # lives on the main event loop
  for i in 0..<n:
    delay(5)
    inc result

proc offload(p: Pool): string {.flow.} =
  let tick = go ticker(20)
  let a = p.go query(80, "a")
  let b = p.go query(80, "b")
  let c = p.go query(80, "c")
  result = await(a) & await(b) & await(c) & "," & $await(tick)

let t0 = epochTime()
let offloaded = run offload(ex)
let took = epochTime() - t0
doAssert offloaded.startsWith("a:doneb:donec:done"), offloaded
doAssert offloaded.endsWith(",20"), offloaded
# three 80 ms blocking calls ran in parallel (not 240 ms) and the main loop
# kept ticking the whole time
doAssert took < 0.2, "offload serialised: " & $took
echo "offload ok: ", offloaded, " in ", int(took * 1000), " ms"

ex.shutdown()
echo "done"
