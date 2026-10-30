## nim c -r examples/echo_server.nim   then:  nc localhost 7000
import ../src/stagelane
import ../src/stagelane/net

proc session(s: TcpStream) {.flow.} =
  try:
    while true:
      let line = s.readLine()
      s.write("you said: " & line & "\n")
  except IOError: discard
  s.close()

proc server(port: int) {.flow.} =
  let l = listenTcp(port)
  echo "listening on ", port
  while true:
    let c = l.accept()
    discard go session(c)      # one cheap task per connection

run server(7000)
