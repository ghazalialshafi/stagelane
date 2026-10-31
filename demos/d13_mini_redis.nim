## 13 - A tiny Redis-like key/value server (SET/GET/INCR/DEL/EXPIRE/PING).
## Single-threaded cooperative scheduling means INCR is atomic without locks:
## 50 clients x 100 INCRs on one key must end at exactly 5000.
## EXPIRE is implemented with a background task per key (a timer, not a thread).
import std/[tables, strutils]
import stagelane, stagelane/net

type Store = ref object
  data: Table[string, string]
  gen: Table[string, int]          # bump on write so stale expiry timers do nothing

proc expireLater(st: Store, key: string, gen, ms: int) {.flow.} =
  delay(ms)
  if st.gen.getOrDefault(key) == gen: st.data.del key

proc exec(st: Store, line: string): string =        # plain (non-flow) proc
  let p = line.splitWhitespace()
  if p.len == 0: return "-ERR empty"
  case p[0].toUpperAscii
  of "PING": "+PONG"
  of "SET":
    st.data[p[1]] = p[2]
    st.gen[p[1]] = st.gen.getOrDefault(p[1]) + 1
    "+OK"
  of "GET":
    if p[1] in st.data: "$" & st.data[p[1]]
    else: "$nil"
  of "DEL":
    if st.data.hasKey(p[1]):
      st.data.del p[1]
      ":1"
    else: ":0"
  of "INCR":
    let v = parseInt(st.data.getOrDefault(p[1], "0")) + 1
    st.data[p[1]] = $v
    st.gen[p[1]] = st.gen.getOrDefault(p[1]) + 1
    ":" & $v
  else: "-ERR unknown command"

proc session(c: TcpStream, st: Store) {.flow.} =
  try:
    while true:
      let line = c.readLine()
      let p = line.splitWhitespace()
      if p.len == 3 and p[0].toUpperAscii == "EXPIRE":
        discard go expireLater(st, p[1], st.gen.getOrDefault(p[1]), parseInt(p[2]))
        c.write("+OK\n")
      else:
        c.write(exec(st, line) & "\n")
  except IOError: discard
  c.close()

proc server(l: TcpListener, st: Store) {.flow.} =
  while true: discard go session(l.accept(), st)

proc call(c: TcpStream, cmd: string): string {.flow.} =
  c.write(cmd & "\n")
  c.readLine()

proc incrClient(port: int) {.flow.} =
  let c = connectTcp("127.0.0.1", port)
  for _ in 1..100: discard call(c, "INCR counter")
  c.close()

proc main() {.flow.} =
  let st = Store()
  let l = listenTcp(0, "127.0.0.1")
  let srv = go server(l, st)
  let port = l.localPort
  let c = connectTcp("127.0.0.1", port)
  echo "PING            -> ", call(c, "PING")
  echo "SET name        -> ", call(c, "SET name stagelane")
  echo "GET name        -> ", call(c, "GET name")
  echo "EXPIRE name 30  -> ", call(c, "EXPIRE name 30")
  delay(60)
  echo "GET name (60ms) -> ", call(c, "GET name")
  scope s:
    for _ in 1..50: discard s.go incrClient(port)
  let total = call(c, "GET counter")
  echo "counter after 50 clients x 100 INCR -> ", total
  doAssert total == "$5000"
  c.close()
  cancel(srv)
  try: await(srv)
  except CancelledError: discard
  l.close()

run main()
