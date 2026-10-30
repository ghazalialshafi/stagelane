## a library module: exported flow procs of every flavour
import ../src/stagelane

proc fib*(n: int): int {.flow.} =                 # pure: compiled to native code
  if n < 2: return n
  fib(n - 1) + fib(n - 2)

proc slowDouble*(x: int): int {.flow.} =          # suspends
  delay(1)
  x * 2

proc fetch*(url: string): string {.flow.} =       # suspends, string in/out
  delay(1)
  "got " & url

proc helper(x: int): int {.flow.} = x + 100       # NOT exported, pure
proc viaHelper*(x: int): int {.flow.} = helper(x) + 1

proc deep*(n: int): int {.flow, heap.} =          # pure but forced onto the heap
  if n == 0: return 0
  deep(n - 1) + 1
