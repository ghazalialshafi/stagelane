## 12 - Echo server load test: 1,000 concurrent TCP connections x 20 round-trips
## = 20,000 request/response pairs, server AND clients on one thread.
import std/[strformat, monotimes, times]
import stagelane, stagelane/net

proc session(c: TcpStream) {.flow.} =
  try:
    while true:
      c.write(c.readLine() & "\n")
  except IOError: discard
  c.close()

proc server(l: TcpListener) {.flow.} =
  while true: discard go session(l.accept())

proc client(port, id, rounds: int): int {.flow.} =
  let c = connectTcp("127.0.0.1", port)
  for r in 1..rounds:
    let msg = &"client {id} round {r}"
    c.write(msg & "\n")
    if c.readLine() == msg: inc result
  c.close()

proc main() {.flow.} =
  const Clients = 1000
  const Rounds = 20
  let l = listenTcp(0, "127.0.0.1", backlog = 1024)
  let srv = go server(l)
  let t0 = getMonoTime()
  var ok = 0
  scope s:
    var cs: seq[Task[int]]
    for i in 1..Clients: cs.add s.go client(l.localPort, i, Rounds)
    for c in cs: ok += await(c)
  let ms = max((getMonoTime() - t0).inMilliseconds, 1)
  echo &"{ok}/{Clients * Rounds} echoes verified in {ms} ms  (~{ok * 1000 div ms} round-trips/s)"
  cancel(srv)
  try: await(srv)
  except CancelledError: discard
  l.close()
  doAssert ok == Clients * Rounds

run main()
