## HTTP hello server on stagelane/net, single event-loop thread.
## nim c -d:release --mm:arc -p:../../src stagelane_http.nim && ./stagelane_http 8081 [stock|zerocopy]
## `stock`    : the public API a user reaches for first (readSome / write: allocates per read)
## `zerocopy` : recvInto / sendFrom on one reusable buffer per connection (readiness I/O)
## `ring`     : the same zero-copy handler on io_uring (Linux 5.11+); falls back to readiness I/O
import stagelane, stagelane/net, stagelane/uring
import std/[os, strutils]

const resp = "HTTP/1.1 200 OK\r\nContent-Type: text/plain\r\nContent-Length: 13\r\n" &
             "Connection: keep-alive\r\n\r\nHello, World!"

let respBuf = resp          # an addressable copy for sendFrom

proc endsRequest(acc: string): bool =
  acc.len >= 4 and acc[^4] == '\r' and acc[^3] == '\n' and acc[^2] == '\r' and acc[^1] == '\n'

proc handleStock(s: TcpStream) {.flow.} =
  var open = true
  try:
    while open:
      var acc = ""
      while not endsRequest(acc):
        let chunk = s.readSome(4096)
        if chunk.len == 0:
          open = false                      # peer closed
          break
        acc.add chunk
      if open: s.write(resp)
  except CatchableError: discard
  s.close()

when compiles(recvInto):
  proc handleZero(s: TcpStream) {.flow.} =
    var buf = newString(4096)
    try:
      while true:
        var got = 0
        while true:
          let n = s.recvInto(addr buf[got], buf.len - got)
          if n == 0: s.close(); return
          got += n
          if got >= 4 and buf[got-4] == '\r' and buf[got-3] == '\n' and buf[got-2] == '\r' and buf[got-1] == '\n': break
          if got == buf.len: buf.setLen(buf.len * 2)
        s.sendFrom(unsafeAddr respBuf[0], respBuf.len)
    except CatchableError: discard
    s.close()

proc serve(port: int, mode: string) {.flow.} =
  let l = listenTcp(port, backlog = 1024)
  echo "listening on ", l.localPort, " mode=", mode
  while true:
    let c = l.accept()
    when compiles(recvInto):
      if mode == "zerocopy" or mode == "ring": discard go handleZero(c)
      else: discard go handleStock(c)
    else:
      discard go handleStock(c)

let port = if paramCount() >= 1: parseInt(paramStr(1)) else: 8081
let mode = if paramCount() >= 2: paramStr(2) else: "stock"
if mode == "ring" and not ringEnable():
  echo "io_uring unavailable: using readiness I/O"
run serve(port, mode)
