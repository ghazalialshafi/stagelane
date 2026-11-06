import ../src/stagelane
# Tests for the fast paths: inline `go` of pure procs, scope pruning,
# the spawn point, loop-step fusion, and the call/return plumbing.

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

proc sq(x: int): int {.flow.} = x * x                      # pure
proc boom(x: int): int {.flow.} =                           # pure, may raise
  if x == 7: raise newException(ValueError, "seven")
  x
proc nap(x: int): int {.flow.} =                            # suspends
  yieldNow()
  x + 1
proc napBoom(x: int): int {.flow.} =
  yieldNow()
  if x == 5: raise newException(ValueError, "five")
  x
proc voidPure(r: ref int) {.flow.} = inc r[]

# --- inline go of pure procs ------------------------------------------------
proc inlineGo(): int {.flow.} =
  let t = go sq(9)
  check t.done, true                    # already finished: ran inside `go`
  check await(t), 81
  let f = go boom(7)
  check f.failed, true
  var msg = ""
  try: discard await(f)
  except ValueError as e: msg = e.msg
  check msg, "seven"
  let r = new int
  await(go voidPure(r))
  check r[], 1
  result = 1
check run inlineGo(), 1

# --- scope: many pure children, failure surfaces at join ----------------------
proc scopePure(n: int): int {.flow.} =
  var total = 0
  scope g:
    for i in 0..<n:
      let t = go(g, sq(i))
      total += await(t)
  total
check run scopePure(3000), (block:
  var s = 0
  for i in 0..<3000: s += i * i
  s)

proc scopePureFail(): string {.flow.} =
  try:
    scope g:
      for i in 0..<1000:
        discard go(g, boom(i))        # i == 7 fails among 1000 inline children
  except ValueError as e: return e.msg
  "no error"
check run scopePureFail(), "seven"

# --- scope pruning: pending + failed children survive compaction ---------------
var counter = 0
proc slow(i: int) {.flow.} =
  yieldNow(); yieldNow()
  inc counter
proc pruneMix(n: int): string {.flow.} =
  counter = 0
  try:
    scope g:
      for i in 0..<n:
        discard go(g, napBoom(i))     # i == 5 fails after one yield
        discard go(g, sq(i))
        discard go(g, slow(i))
  except ValueError as e: return e.msg
  "no error"
check run pruneMix(2000), "five"

proc pruneAllOk(n: int): int {.flow.} =
  counter = 0
  scope g:
    for i in 0..<n: discard go(g, slow(i))
  counter
check run pruneAllOk(5000), 5000       # spawn point + pruning: everyone finishes

# --- spawn point keeps the parent's progress consistent -------------------------
proc spawnOrder(n: int): int {.flow.} =
  var spawned = 0
  var finishedAtEnd = 0
  scope g:
    for i in 0..<n:
      discard go(g, slow(i))
      inc spawned                      # runs after `go` returns, whether or not it yielded
  finishedAtEnd = counter
  spawned * 100000 + (if finishedAtEnd == n: 1 else: 0)
counter = 0
check run spawnOrder(4000), 4000 * 100000 + 1

# --- for loops around suspension points (fstep fusion) ---------------------------
proc loops(): seq[int] {.flow.} =
  for i in 0..4:
    if i == 1: continue
    if i == 4: break
    yieldNow()
    result.add i
  for i in 0..<3:
    for j in 0..<3:
      if j == 2: break
      result.add nap(i * 10 + j)
  for x in @[7, 8, 9]:
    yieldNow()
    if x == 8: continue
    result.add x
  for i in countup(1, 3): result.add nap(i) * 100
check run loops(), @[0, 2, 3, 1, 2, 11, 12, 21, 22, 7, 9, 200, 300, 400]

# --- plain call chain with results flowing back through many frames ----------------
proc chain(n: int): int {.flow.} =
  if n == 0: return 0
  result = nap(n) + chain(n - 1)
check run chain(200), (block:
  var s = 0
  for n in 1..200: s += n + 1
  s)

# --- exceptions through frames still reach the caller ---------------------------------
proc thrower(n: int): int {.flow.} =
  if n == 0: raise newException(IOError, "bottom")
  nap(n) + thrower(n - 1)
proc catcher(): string {.flow.} =
  try: discard thrower(50)
  except IOError as e: return e.msg
  "none"
check run catcher(), "bottom"

# --- pooled frames are clean when reused ------------------------------------------------
proc dirty(x: int): int {.flow.} =
  var acc: int                         # must start at 0 on every call
  var s: string                        # must start empty
  for i in 0..<x: acc += i; s.add 'x'
  yieldNow()
  acc + s.len
proc reuse(): bool {.flow.} =
  for k in 0..<300:
    if dirty(10) != 55: return false
    if dirty(0) != 0: return false
  true
check run reuse(), true
