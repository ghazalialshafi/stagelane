## nim c -r examples/use_lib.nim
import ../src/stagelane
import shop_lib

static:
  doAssert neverSuspends(taxed(Price(cents: 1)))       # compile-time proof: no frame, no loop
  doAssert not neverSuspends(lookup("x"))

proc main() {.flow.} =
  scope s:                                                # structured concurrency
    let a = s.go total(@["apple", "pear"])
    let b = s.go total(@["fig"])
    echo "a = ", await(a).cents, "  b = ", await(b).cents

run main()
echo taxed(Price(cents: 1000)).cents           # a flow proc is also an ordinary proc
echo lookup("kiwi").cents                      # ... even one that suspends (runs the loop for you)
