## nim c -r examples/hello.nim
import ../src/stagelane

proc fetch(name: string, ms: int): string {.flow.} =
  delay(ms)                       # suspends this task, not the thread
  "hello from " & name

proc main() {.flow.} =
  # structured concurrency: the scope waits for (or cancels) its children
  var results: seq[Task[string]]
  scope g:
    for i, ms in [30, 10, 20]:
      results.add go(g, fetch("task" & $i, ms))
  for t in results: echo await(t)

run main()
