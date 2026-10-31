## 17 - Concurrent web crawler over a simulated 3,000-page site (each fetch = 5-15 ms).
## 40 crawler tasks share an unbounded frontier channel and a visited set; a
## WaitGroup tracks outstanding URLs so we know exactly when the crawl is complete.
## Sequentially this is ~30 seconds; here it takes well under a second.
import std/[sets, strformat, monotimes, times]
import stagelane

const Pages = 3000

proc linksOf(p: int): array[3, int] =          # deterministic synthetic link graph
  [(p * 7 + 1) mod Pages, (p * 13 + 5) mod Pages, (p + 1) mod Pages]

proc fetch(p: int): array[3, int] {.flow.} =
  delay(5 + (p * 31) mod 11)                   # network latency 5..15 ms
  linksOf(p)

type Crawl = ref object
  frontier: Chan[int]
  seen: HashSet[int]
  pending: WaitGroup
  fetched: int

proc enqueue(c: Crawl, p: int) =
  if p notin c.seen:
    c.seen.incl p
    c.pending.add()
    discard c.frontier.trySend(p)              # unbounded channel: never full

proc crawler(c: Crawl) {.flow.} =
  while true:
    let p = c.frontier.recvOpt()
    if p.isNone: break
    let links = fetch(p.get)
    inc c.fetched
    for l in links: enqueue(c, l)
    c.pending.done()

proc main() {.flow.} =
  let c = Crawl(frontier: newChan[int](-1), pending: newWaitGroup())
  let t0 = getMonoTime()
  scope s:
    for _ in 1..40: discard s.go crawler(c)
    enqueue(c, 0)
    c.pending.wait()                           # every discovered URL processed
    c.frontier.close()                         # lets the 40 crawlers exit
  let ms = (getMonoTime() - t0).inMilliseconds
  echo &"crawled {c.fetched} unique pages in {ms} ms with 40 concurrent fetchers"
  echo &"sequential estimate: {c.fetched * 10} ms  ->  ~{c.fetched * 10 div max(int(ms), 1)}x faster"

run main()
