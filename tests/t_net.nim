import ../src/stagelane
import ../src/stagelane/net

proc handle(s: TcpStream) {.flow.} =
  try:
    while true:
      let line = s.readLine()
      if line == "quit": break
      s.write("echo: " & line & "\n")
  except IOError:
    discard
  s.close()

proc serve(l: TcpListener, n: int) {.flow.} =
  scope g:
    for i in 0..<n:
      let c = l.accept()
      discard go(g, handle(c))

proc client(port, id: int): string {.flow.} =
  let s = connectTcp("127.0.0.1", port)
  for i in 0..<3:
    s.write("hello " & $id & "-" & $i & "\n")
    result &= s.readLine() & ";"
  s.write("quit\n")
  s.close()

proc main(): string {.flow.} =
  let l = listenTcp(0, "127.0.0.1")
  let port = l.localPort
  let srv = go serve(l, 3)
  let a = go client(port, 1)
  let b = go client(port, 2)
  let c = go client(port, 3)
  result = await(a) & "|" & await(b) & "|" & await(c)
  await(srv)
  l.close()

echo run main()
