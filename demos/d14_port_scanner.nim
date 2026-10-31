## 14 - Concurrent port scanner / health checker (localhost only).
## Opens 7 listeners on random ephemeral ports, then probes every port between the
## lowest and highest of them (typically 5,000-28,000 ports) with at most 500
## connections in flight (Semaphore) and a per-probe timeout. Finds all 7.
## (Other local services in that range may show up too - that's what a scanner does.)
import std/[strformat, monotimes, times, algorithm]
import stagelane, stagelane/net

proc probe(host: string, port: int): bool {.flow.} =
  try:
    let c = withTimeout(200, connectTcp(host, port))
    c.close()
    true
  except OSError, TimeoutError: false

proc limitedProbe(sem: Semaphore, port: int, open: ptr seq[int]) {.flow.} =
  withPermit(sem):
    if probe("127.0.0.1", port): open[].add port

proc acceptAndDrop(l: TcpListener) {.flow.} =
  while true: l.accept().close()

proc main() {.flow.} =
  var listeners: seq[TcpListener]
  var ours: seq[int]
  for _ in 1..7:
    let l = listenTcp(0, "127.0.0.1")
    listeners.add l; ours.add l.localPort
    discard go acceptAndDrop(l)
  ours.sort()
  let lo = max(1024, ours[0] - 200)
  let hi = ours[^1] + 200
  var found: seq[int]
  let sem = newSemaphore(500)
  let t0 = getMonoTime()
  scope s:
    for port in lo..hi: discard s.go limitedProbe(sem, port, addr found)
  found.sort()
  echo &"scanned {hi - lo + 1} ports ({lo}..{hi}) in {(getMonoTime() - t0).inMilliseconds} ms"
  echo "planted listeners: ", ours
  echo "scanner found    : ", found
  var allFound = true
  for p in ours:
    if p notin found: allFound = false
  doAssert allFound

run main()
