## 11 - TCP chat room. One task per connection plus one writer task per client
## with its own outbound channel, so a slow reader can never stall the room.
## Self-test: 6 bot clients join, each says 5 lines, each must hear the other 25.
import std/strformat
import stagelane, stagelane/net

type Room = ref object
  clients: seq[Chan[string]]

proc writer(c: TcpStream, outq: Chan[string]) {.flow.} =
  try:
    while true:
      let m = outq.recvOpt()
      if m.isNone: break
      c.write(m.get & "\n")
  except IOError, OSError: discard

proc session(c: TcpStream, room: Room, id: int) {.flow.} =
  let outq = newChan[string](64)
  room.clients.add outq
  let w = go writer(c, outq)
  try:
    while true:
      let line = c.readLine()
      for q in room.clients:
        if q != outq: discard q.trySend(&"[user{id}] {line}")   # never block on slow clients
  except IOError: discard
  room.clients.delete(room.clients.find(outq))
  outq.close()
  await(w)
  c.close()

proc server(l: TcpListener, room: Room) {.flow.} =
  var id = 0
  while true:
    let c = l.accept()
    inc id
    discard go session(c, room, id)

proc bot(port, me, bots, lines: int): int {.flow.} =
  let c = connectTcp("127.0.0.1", port)
  delay(50)                                  # let everybody join first
  for k in 1..lines:
    c.write(&"hello {k} from bot {me}\n")
    delay(2)
  let expected = (bots - 1) * lines
  for _ in 1..expected:
    discard c.readLine()
    inc result
  c.close()

proc main() {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let room = Room()
  let srv = go server(l, room)
  var heard = 0
  scope s:
    var bs: seq[Task[int]]
    for me in 1..6: bs.add s.go bot(l.localPort, me, 6, 5)
    for b in bs: heard += await(b)
  echo &"6 bots exchanged messages: {heard} lines delivered (expected 150)"
  cancel(srv)
  try: await(srv)
  except CancelledError: discard
  l.close()
  doAssert heard == 150

run main()
