## 20 - Map-reduce word count across worker threads using SharedChan.
## Build: nim c --threads:on --mm:atomicArc -d:flowThreads -d:danger d20_mapreduce_wordcount.nim
##
## main loop (producer) --SharedChan[string] chunks--> N mapper tasks on a Pool
##                                                         |  (CPU-bound counting)
## main loop (reducer)  <--SharedChan[Counts]-------------+
## The result is verified against a plain sequential count. Speedup scales with
## the number of CPU cores (`countProcessors()`); on a 1-core box expect ~1x.
import std/[tables, strutils, strformat, monotimes, times, cpuinfo]
import stagelane, stagelane/exec

type Counts = seq[(string, int)]

const Vocab = ["stage", "lane", "task", "flow", "pause", "resume", "scope", "chan",
               "select", "mutex", "event", "timer", "socket", "pool", "thread", "frame"]

proc makeChunk(seed, words: int): string =
  var x = uint32(seed) * 2654435761'u32 + 12345'u32
  var parts = newSeqOfCap[string](words)
  for _ in 1..words:
    x = x * 1664525'u32 + 1013904223'u32
    parts.add Vocab[int((x shr 16) mod uint32(Vocab.len))]
  parts.join(" ")

proc countWords(text: string): Counts =
  var t = initCountTable[string]()
  for w in text.splitWhitespace(): t.inc w
  for k, v in t: result.add (k, v)

proc merge(dst: var CountTable[string], src: Counts) =   # plain proc: destructuring is fine here
  for (w, c) in src: dst.inc(w, c)

proc toCounts(t: CountTable[string]): Counts =
  for k, v in t: result.add (k, v)

proc mapper(chunks: SharedChan[string], results: SharedChan[Counts]) {.flow.} =
  var local = initCountTable[string]()
  try:
    while true:
      let text = chunks.recv()                 # parks (no thread blocked) when empty
      local.merge countWords(text)
  except SharedChanClosed: discard             # input closed and drained
  results.send(local.toCounts())

proc mapReduce(nChunks, words, mappers: int): CountTable[string] {.flow.} =
  let pool = newPool(mappers)
  let chunks = newSharedChan[string](8)
  let results = newSharedChan[Counts](mappers)
  var jobs: seq[Task[void]]
  for _ in 1..mappers: jobs.add pool.go mapper(chunks, results)
  for i in 1..nChunks: chunks.send(makeChunk(i, words))   # back-pressure from cap=8
  chunks.close()
  result = initCountTable[string]()
  for _ in 1..mappers:                         # reduce
    let part = results.recv()
    result.merge part
  for j in jobs: await(j)
  pool.shutdown()

proc main() {.flow.} =
  const Chunks = 64
  const Words = 40_000
  var expected = initCountTable[string]()
  var t0 = getMonoTime()
  for i in 1..Chunks:
    expected.merge countWords(makeChunk(i, Words))
  let seqMs = (getMonoTime() - t0).inMilliseconds
  t0 = getMonoTime()
  let got = mapReduce(Chunks, Words, 4)
  let parMs = (getMonoTime() - t0).inMilliseconds
  var total = 0
  for _, v in got: total += v
  echo &"{total} words counted; sequential {seqMs} ms, 4 mapper threads {parMs} ms  (CPU cores: {countProcessors()})"
  var top = got
  top.sort()                                   # descending by count
  var shown: seq[(string, int)]
  for k, v in top:
    if shown.len < 3: shown.add (k, v)
  echo "top words: ", shown
  doAssert got == expected, "map-reduce result differs from sequential count"
  echo "verified: identical to the sequential result"

run main()
