## 04 - Multi-stage pipeline: generate -> parse -> enrich (x4) -> sink.
## Small buffers between stages give automatic back-pressure: a slow stage
## throttles the fast producer, so memory stays bounded.
import std/[strutils, monotimes, times, strformat]
import stagelane

proc generate(outp: Chan[string], n: int) {.flow.} =
  for i in 1..n: outp.send("record," & $i & "," & $(i * 3))
  outp.close()

proc parse(inp: Chan[string], outp: Chan[(int, int)]) {.flow.} =
  while true:
    let l = inp.recvOpt()
    if l.isNone: break
    let f = l.get.split(',')
    outp.send((parseInt(f[1]), parseInt(f[2])))
  outp.close()

proc enrichOne(inp: Chan[(int, int)], outp: Chan[int]) {.flow.} =
  while true:
    let r = inp.recvOpt()
    if r.isNone: break
    delay(2)                       # slow stage: pretend DB lookup
    outp.send(r.get[0] + r.get[1])

proc enrichStage(inp: Chan[(int, int)], outp: Chan[int], workers: int) {.flow.} =
  scope s:                         # fan-out: N workers share one input
    for _ in 1..workers: discard s.go enrichOne(inp, outp)
  outp.close()                     # fan-in: close only after ALL workers end

proc sink(inp: Chan[int]): (int, int) {.flow.} =
  while true:
    let v = inp.recvOpt()
    if v.isNone: break
    result[0] += v.get
    inc result[1]

proc main() {.flow.} =
  let c1 = newChan[string](4)
  let c2 = newChan[(int, int)](4)
  let c3 = newChan[int](4)
  let t0 = getMonoTime()
  var checksum, count: int
  scope s:
    discard s.go generate(c1, 500)
    discard s.go parse(c1, c2)
    discard s.go enrichStage(c2, c3, 4)
    let k = s.go sink(c3)
    (checksum, count) = await(k)
  echo &"processed {count} records, checksum {checksum}  (expected {4 * (500 * 501 div 2)})"
  echo &"elapsed {(getMonoTime() - t0).inMilliseconds} ms  (a single enricher would need ~1000 ms)"

run main()
