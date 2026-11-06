{.feature: "assumeSync".}
import std/[syncio, threadpool, atomics, monotimes, channels, ioring, cmdline]

var done: int
var sink: int

template report(name: string; ops: int; t0: MonoTime) =
  let ns = int(getMonoTime().ticks) - int(t0.ticks)
  echo "RESULT\tnimony\t", name, "\t", ops, "\t", ns div 1000  # microseconds

# ---- helpers
proc waitFor(n: int) =
  while atomicLoad(done, moAcquire) < n:
    if not poolHelp(): discard reactorPoll(0.cint)
  atomicStore(done, 0, moRelease)

proc yieldNow() {.passive.} =
  let c = delay()
  submit(c)
  suspend()

# ---- 1. impure call chain (cold-path suspend)
proc leaf(x: int): int {.passive.} =
  if x < 0: yieldNow()
  result = x + 1
proc caller(n: int) {.passive.} =
  var s = 0
  for i in 0..<n: s += leaf(i)
  atomicStore(sink, s, moRelaxed)
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 2. yield switch
proc yielder(n: int) {.passive.} =
  for i in 0..<n: yieldNow()
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 3. spawn tiny tasks
proc tiny(x: int) {.passive.} =
  discard atomicFetchAdd(sink, x, moRelaxed)
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 4. fanout n tasks x 3 yields
proc y3() {.passive.} =
  yieldNow(); yieldNow(); yieldNow()
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 5. ping-pong
proc pinger(a: Sender[int]; b: Receiver[int]; n: int) {.passive.} =
  var v = 0
  try:
    for i in 0..<n:
      discard a.send(i)
      discard b.recv(v)
  except: discard
  discard atomicFetchAdd(done, 1, moRelease)
proc ponger(a: Receiver[int]; b: Sender[int]; n: int) {.passive.} =
  var v = 0
  try:
    for i in 0..<n:
      discard a.recv(v)
      discard b.send(v + 1)
  except: discard
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 6. timers
proc sleeper(ms: int) {.passive.} =
  let c = delay()
  discard submitTimeout(afterMs(ms), c)
  suspend()
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 7. cpu
proc crunch(n: int) {.passive.} =
  var r = 0
  for i in 1..n: r += i mod 7
  discard atomicFetchAdd(sink, r, moRelaxed)
  discard atomicFetchAdd(done, 1, moRelease)

# ---- 8. producer/consumer throughput
proc producer(s: Sender[int]; n: int) {.passive.} =
  try:
    for i in 0..<n: discard s.send(i)
    s.flush()
  except: discard
  discard atomicFetchAdd(done, 1, moRelease)
proc consumer(r: Receiver[int]; n: int) {.passive.} =
  var v = 0
  var t = 0
  try:
    for i in 0..<n:
      discard r.recv(v)
      t += v
  except: discard
  atomicStore(sink, t, moRelaxed)
  discard atomicFetchAdd(done, 1, moRelease)

proc main() =
  var w = 1
  if paramCount() >= 1:
    w = 0
    for ch in paramStr(1):
      w = w * 10 + (ord(ch) - ord('0'))
  initPool(w)
  var t0: MonoTime
  var only = ""
  var pn = 20_000
  if paramCount() >= 3:
    pn = 0
    for ch in paramStr(3): pn = pn * 10 + (ord(ch) - ord('0'))
  if paramCount() >= 2: only = paramStr(2)

  if only == "" or only == "call": t0 = getMonoTime(); submit(delay(caller(10_000_000))); waitFor(1); report("call_10M", 10_000_000, t0)
  if only == "" or only == "yield": t0 = getMonoTime(); submit(delay(yielder(2_000_000))); waitFor(1); report("yield_2M", 2_000_000, t0)
  if only == "" or only == "spawn":
   t0 = getMonoTime()
   for i in 0..<200_000: submit(delay(tiny(i)))
   waitFor(200_000); report("spawn_200k", 200_000, t0)
  if only == "" or only == "fanout":
   t0 = getMonoTime()
   for i in 0..<100_000: submit(delay(y3()))
   waitFor(100_000); report("fanout_100k_x3yield", 400_000, t0)
  if only == "" or only == "pingpong":
   block:
    let (r1, s1) = channel[int](1)
    let (r2, s2) = channel[int](1)
    t0 = getMonoTime()
    submit(delay(pinger(s1, r2, 200_000)))
    submit(delay(ponger(r1, s2, 200_000)))
    waitFor(2); report("pingpong_200k", 400_000, t0)
  if only == "" or only == "timers":
   t0 = getMonoTime()
   for i in 0..<100_000: submit(delay(sleeper(1 + i mod 5)))
   waitFor(100_000); report("timers_100k", 100_000, t0)
  if only == "" or only == "cpu":
   t0 = getMonoTime()
   for i in 0..<64: submit(delay(crunch(2_000_000)))
   waitFor(64); report("cpu_64x2M", 64, t0)
  if only == "" or only == "pipe":
   block:
    let (r, s) = channel[int](128)
    t0 = getMonoTime()
    submit(delay(producer(s, pn)))
    submit(delay(consumer(r, pn)))
    waitFor(2); report("chan_pipe_" & $pn, pn, t0)
  shutdownPool()
main()
