## 10 - In-process pub/sub broker. Publishers push to topics; the broker fans
## each message out to every subscriber's private channel, using `select` to
## multiplex incoming publishers and a shutdown timeout.
import std/[tables, strformat]
import stagelane

type Msg = tuple[topic: string, body: string]

proc publisher(name, topic: string, n, every: int, bus: Chan[Msg]) {.flow.} =
  for i in 1..n:
    delay(every)
    bus.send((topic, name & " msg " & $i))

proc broker(bus: Chan[Msg], subs: Table[string, seq[Chan[string]]]) {.flow.} =
  while true:
    var got: Msg
    var idle = false
    select:
      bus.recv(m): got = m
      timeout(100): idle = true
    if idle: break
    for ch in subs.getOrDefault(got.topic): ch.send(got.body)
  for _, lst in subs:
    for ch in lst: ch.close()

proc subscriber(name: string, ch: Chan[string]): int {.flow.} =
  while true:
    let m = ch.recvOpt()
    if m.isNone: break
    inc result
  echo &"  {name} received {result} messages"

proc main() {.flow.} =
  let bus = newChan[Msg](8)
  let sports1, sports2, news1 = newChan[string](32)
  var subs: Table[string, seq[Chan[string]]]
  subs["sports"] = @[sports1, sports2]
  subs["news"] = @[news1]
  scope s:
    let a = s.go subscriber("alice  [sports]", sports1)
    let b = s.go subscriber("bob    [sports]", sports2)
    let c = s.go subscriber("carol  [news]  ", news1)
    discard s.go broker(bus, subs)
    discard s.go publisher("ESPN", "sports", 10, 7, bus)
    discard s.go publisher("BBC", "news", 6, 11, bus)
    discard s.go publisher("Sky", "sports", 5, 13, bus)
    doAssert await(a) == 15 and await(b) == 15 and await(c) == 6
  echo "pub/sub OK: 21 published, 36 deliveries"

run main()
