## 03 - Classic worker pool over a channel. 8 workers drain 200 jobs of 10 ms:
## ideal time = 200*10/8 = 250 ms (vs 2000 ms sequentially).
import std/[monotimes, times, strformat]
import stagelane

proc worker(id: int, jobs: Chan[int], results: Chan[(int, int)], done: ptr array[8, int]) {.flow.} =
  while true:
    let j = jobs.recvOpt()
    if j.isNone: break
    delay(10)                      # simulated work
    inc done[id]
    results.send((j.get, j.get * j.get))

proc main() {.flow.} =
  let jobs = newChan[int](16)
  let results = newChan[(int, int)](256)
  var perWorker: array[8, int]
  let t0 = getMonoTime()
  scope s:
    for id in 0..7: discard s.go worker(id, jobs, results, addr perWorker)
    for j in 1..200: jobs.send(j)  # back-pressure: blocks when buffer is full
    jobs.close()
  var sum = 0
  while results.len > 0: sum += results.recv()[1]
  echo &"sum of squares = {sum}  (expected 2686700)"
  echo &"elapsed {(getMonoTime() - t0).inMilliseconds} ms, jobs per worker: {perWorker}"

run main()
