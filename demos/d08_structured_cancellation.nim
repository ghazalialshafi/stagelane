## 08 - Structured concurrency: one failure cancels its siblings, nothing leaks.
## A "deploy" runs 6 parallel steps; the pre-flight check fails after 30 ms. The
## other steps are cancelled wherever they are parked and run their cleanup code.
## NOTE: `scope` joins children in spawn order, so a failure is noticed as soon as
## every EARLIER child has finished. Spawn fail-fast tasks (checks) first.
import std/[strformat, monotimes, times]
import stagelane

var cleaned = 0

proc step(name: string, ms: int, fail: bool) {.flow.} =
  try:
    delay(ms)
    if fail: raise newException(ValueError, name & " failed")
    echo "  finished ", name
  finally:
    inc cleaned                    # always runs: success, error, or cancellation

proc deploy() {.flow.} =
  scope s:
    discard s.go step("preflight", 30,   true)    # fails first -> cancels the rest
    discard s.go step("build",     10,   false)
    discard s.go step("lint",      15,   false)
    discard s.go step("test",      2000, false)
    discard s.go step("upload",    3000, false)
    discard s.go step("notify",    5000, false)

proc main() {.flow.} =
  let t0 = getMonoTime()
  try:
    deploy()
  except ValueError as e:
    echo &"deploy aborted: {e.msg}"
  let ms = (getMonoTime() - t0).inMilliseconds
  echo &"all 6 steps cleaned up: {cleaned == 6}; took {ms} ms instead of 5000"
  doAssert cleaned == 6 and ms < 500

run main()
