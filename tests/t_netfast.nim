import ../src/stagelane
import ../src/stagelane/net
when defined(useRing):                 # run every test below through io_uring
  import ../src/stagelane/uring
  if not ringEnable():
    echo "io_uring unavailable here: skipped"
    quit 0
# Persistent (edge-triggered) fd registration and the drained-read shortcut:
# idle waits, large transfers, write backpressure, fd-number reuse, EOF, cancellation.

template check(e, v: untyped) =
  let got = e
  if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
  else: echo "ok   ", astToStr(e)

# ---- 1. echo server with idle gaps: every request parks and wakes on an edge ----------------
proc echoLoop(s: TcpStream) {.flow.} =
  var buf = newString(1024)
  try:
    while true:
      let n = s.recvInto(addr buf[0], buf.len)
      if n == 0: break
      s.sendFrom(addr buf[0], n)
  except CatchableError: discard
  s.close()

proc acceptN(l: TcpListener, n: int) {.flow.} =
  scope g:
    for i in 0..<n:
      let c = l.accept()
      discard go(g, echoLoop(c))

proc idleClient(port, id, rounds: int): int {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  for r in 0..<rounds:
    delay(1 + id mod 3)                       # idle gap: the server is parked in waitReadable
    let msg = "ping " & $id & ":" & $r
    s.write(msg)
    var got = ""
    while got.len < msg.len: got.add s.readSome(64)
    if got == msg: inc result
  s.close()

proc t1(): int {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let port = l.localPort
  var total = 0
  scope g:
    discard go(g, acceptN(l, 40))
    var ts: seq[Task[int]]
    for i in 0..<40: ts.add go(g, idleClient(port, i, 25))
    for t in ts: total += await(t)
  l.close()
  total
check run t1(), 40 * 25

# ---- 2. large transfer: partial reads (r == n must NOT be taken as "drained") ---------------
proc sink(s: TcpStream, want: int): int {.flow.} =
  var buf = newString(4096)                   # small buffer: many full reads in a row
  var got = 0
  while got < want:
    let n = s.recvInto(addr buf[0], buf.len)
    if n == 0: break
    got += n
  s.sendFrom(addr buf[0], 1)                  # ack
  got

proc bigServer(l: TcpListener, want: int): int {.flow.} =
  let c = l.accept()
  result = sink(c, want)
  c.close()

proc bigClient(port, size: int): int {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  let payload = newString(size)               # bigger than the socket buffers: write backpressure
  s.write(payload)                            # parks in waitWritable until the server drains
  var ack = ""
  while ack.len < 1: ack.add s.readSome(8)
  s.close()
  ack.len

proc t2(): int {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let size = 8 * 1024 * 1024
  scope g:
    let srv = go(g, bigServer(l, size))
    let cl = go(g, bigClient(l.localPort, size))
    discard await(cl)
    result = await(srv)
  l.close()
check run t2(), 8 * 1024 * 1024

# ---- 3. fd numbers are reused: thousands of short connections ---------------------------------
proc oneShot(s: TcpStream) {.flow.} =
  try:
    let line = s.readLine()
    s.write(line & "!\n")
  except CatchableError: discard
  s.close()

proc churnServer(l: TcpListener, n: int) {.flow.} =
  for i in 0..<n:
    let c = l.accept()
    discard go oneShot(c)

proc churnClient(port, n: int): int {.flow.} =
  for i in 0..<n:
    let s = connectTcp("127.0.0.1", port)
    s.write("n" & $i & "\n")
    if s.readLine() == "n" & $i & "!": inc result
    s.close()

proc t3(): int {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  scope g:
    discard go(g, churnServer(l, 3000))
    result = await(go(g, churnClient(l.localPort, 3000)))
  l.close()
check run t3(), 3000

# ---- 4. EOF is sticky: reads keep returning 0, never park forever ------------------------------
proc eofServer(l: TcpListener): seq[int] {.flow.} =
  let c = l.accept()
  var buf = newString(16)
  for i in 0..3: result.add c.recvInto(addr buf[0], buf.len)
  c.close()
proc eofClient(port: int) {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  s.write("abc")
  delay(5)
  s.close()
proc t4(): seq[int] {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  scope g:
    discard go(g, eofClient(l.localPort))
    result = await(go(g, eofServer(l)))
  l.close()
check run t4(), @[3, 0, 0, 0]

# ---- 5. a cancelled wait leaves the socket usable -----------------------------------------------
proc slowPeer(l: TcpListener) {.flow.} =
  let c = l.accept()
  delay(60)
  c.write("late")
  delay(20)
  c.close()
proc t5(): string {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  scope g:
    discard go(g, slowPeer(l))
    let s = connectTcp("127.0.0.1", l.localPort)
    var first = "none"
    try:
      first = withTimeout(10, s.readSome(16))         # times out while parked on the edge
    except TimeoutError: first = "timeout"
    let second = s.readSome(16)                        # the same socket, waited on again
    s.close()
    result = first & "/" & second
  l.close()
check run t5(), "timeout/late"

# ---- 6. connect refused is reported, not hung ------------------------------------------------------
proc t6(): bool {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let port = l.localPort
  l.close()
  try:
    let s = connectTcp("127.0.0.1", port)
    s.close()
    return false
  except OSError: return true
check run t6(), true

# ---- 7. serveTcp: a pausing handler passed by name ------------------------------------------------
proc slowHello(s: TcpStream) {.flow.} =
  try:
    let who = s.readLine()
    delay(3)                                   # the handler pauses
    s.write("hello " & who & "\n")
  except CatchableError: discard
  s.close()

proc helloServer(l: TcpListener) {.flow.} = serveTcp(l, slowHello)

proc helloClient(port, i: int): string {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  s.write("c" & $i & "\n")
  result = s.readLine()
  s.close()

proc t7(): string {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let port = l.localPort
  scope g:
    let srv = go(g, helloServer(l))
    var rs: seq[Task[string]]
    for i in 0..<5: rs.add go(g, helloClient(port, i))
    for r in rs: result &= await(r) & ";"
    srv.cancel()
  l.close()
check run t7(), "hello c0;hello c1;hello c2;hello c3;hello c4;"

# ---- 8. serveTcp with the handler held in a value (FlowFn) ------------------------------------------
proc valueServer(l: TcpListener, h: FlowFn[proc (c: TcpStream)]) {.flow.} = serveTcp(l, h)

proc t8(): string {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let port = l.localPort
  scope g:
    let srv = go(g, valueServer(l, flowFn(slowHello)))
    var rs: seq[Task[string]]
    for i in 0..<3: rs.add go(g, helloClient(port, i))
    for r in rs: result &= await(r) & ";"
    srv.cancel()
  l.close()
check run t8(), "hello c0;hello c1;hello c2;"

# ---- 9. serveTcp with a receiver / context ---------------------------------------------------------------
type App = ref object
  greeting: string
  served: int
var ctxEvals = 0
proc makeGreeting(): string = inc ctxEvals; "howdy"

proc appHandler(app: App, punct: string, s: TcpStream) {.flow.} =
  try:
    let who = s.readLine()
    delay(2)
    inc app.served                             # a ref receiver: one object shared by all connections
    s.write(app.greeting & " " & who & punct & "\n")
  except CatchableError: discard
  s.close()

proc appServer(l: TcpListener, app: App) {.flow.} =
  serveTcp(l, appHandler, app, "!")            # appHandler(app, "!", conn)

proc appServerBound(l: TcpListener, app: App) {.flow.} =
  serveTcp(l, flowFn(appHandler, app, "?"))    # the same through a value

proc greetServer(l: TcpListener) {.flow.} =
  serveTcp(l, appHandler, App(greeting: makeGreeting()), ".")   # context is evaluated once

proc t9(): string {.flow.} =
  let app = App(greeting: "hi")
  for variant in 0..2:
    let l = listenTcp(0, "127.0.0.1")
    let port = l.localPort
    scope g:
      let srv =
        if variant == 0: go(g, appServer(l, app))
        elif variant == 1: go(g, appServerBound(l, app))
        else: go(g, greetServer(l))
      var rs: seq[Task[string]]
      for i in 0..<3: rs.add go(g, helloClient(port, i))
      for r in rs: result &= await(r) & ";"
      srv.cancel()
    l.close()
  result &= $app.served & "," & $ctxEvals
check run t9(), "hi c0!;hi c1!;hi c2!;hi c0?;hi c1?;hi c2?;howdy c0.;howdy c1.;howdy c2.;6,1"
