## Offload blocking code to worker threads without stalling the event loop.
##   nim c --threads:on --mm:atomicArc -d:flowThreads -r examples/offload.nim
import ../src/stagelane
import ../src/stagelane/exec
import std/os

# plain, blocking third-party style code ...
proc slowQuery(ms: int, name: string): string =
  os.sleep(ms)
  "result of " & name

# ... wrapped in a flow proc so the pool can run it
proc query(ms: int, name: string): string {.flow.} =
  slowQuery(ms, name)

proc heartbeat(): int {.flow.} =          # keeps running on the main loop
  for i in 1..10:
    delay(20)
    echo "  tick ", i
    inc result

proc main() {.flow.} =
  let pool = newPool(3)
  let beat = go heartbeat()
  let a = pool.go query(100, "users")      # three blocking calls in parallel
  let b = pool.go query(100, "orders")
  let c = pool.go query(100, "stock")
  echo await(a), " / ", await(b), " / ", await(c)
  echo "heartbeats: ", await(beat)
  pool.shutdown()

run main()
