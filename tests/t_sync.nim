import ../src/stagelane
import std/options

proc producer(ch: Chan[int], n: int) {.flow.} =
  for i in 1..n:
    ch.send(i)
  ch.close()

proc consumer(ch: Chan[int]): int {.flow.} =
  while true:
    let v = ch.recvOpt()
    if v.isNone: break
    result += v.get

proc pipeline(): int {.flow.} =
  let ch = newChan[int](2)
  let p = go producer(ch, 100)
  let c = go consumer(ch)
  await(p)
  result = await(c)

echo run pipeline()

proc counter(m: Mutex, n: ptr int, k: int) {.flow.} =
  for i in 0..<k:
    withLock(m):
      let old = n[]
      yieldNow()
      n[] = old + 1

proc mutexTest(): int {.flow.} =
  var n = 0
  let m = newMutex()
  let a = go counter(m, addr n, 50)
  let b = go counter(m, addr n, 50)
  await(a); await(b)
  result = n

echo run mutexTest()

proc sender(b: Chan[string]) {.flow.} =
  delay(20)
  b.send("hello")

proc selecting(): string {.flow.} =
  let a = newChan[int](1)
  let b = newChan[string](1)
  discard go sender(b)
  var got = 0
  while got < 2:
    select:
      a.recv(x): result &= "int" & $x
      b.recv(s):
        result &= s & ";"
        inc got
      timeout(10):
        result &= "t;"
        inc got

echo run selecting()

proc job(s: Semaphore, act, mx: ptr int) {.flow.} =
  withPermit(s):
    inc act[]
    if act[] > mx[]: mx[] = act[]
    delay(5)
    dec act[]

proc semTest(): int {.flow.} =
  let s = newSemaphore(2)
  var active = 0
  var maxActive = 0
  let wg = newWaitGroup(6)
  proc dummy() = discard
  scope g:
    for i in 0..<6:
      discard go(g, job(s, addr active, addr maxActive))
  result = maxActive

echo run semTest()
