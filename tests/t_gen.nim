import ../src/stagelane

type C = ref object of Frame

proc id[T](x: T): T {.flow: C.} = x

proc twice[T](x: T): seq[T] {.flow: C.} =
  var a = id(x)
  result.add a
  result.add id(a)

proc pick[T](a, b: T, first: bool): T {.flow: C.} =
  if first: return id(a)
  result = id(b)

proc zero[T](_: typedesc[T]): T {.flow: C.} =
  result = id(default(T))

proc rep[T](x: T, n: static int): seq[T] {.flow: C.} =
  for i in 0..<n: result.add id(x)

proc sizes(T: typedesc): int {.flow: C.} =
  result = id(sizeof(T))

proc fact[T: SomeInteger](n: T): T {.flow: C.} =
  if n <= 1: return 1
  result = n * fact(n - 1)

proc viaGeneric(): string {.flow: C.} =
  let a = id(3)
  let b = id("s")
  result = $a & b & $twice(2.5).len & $pick(1, 2, false)

proc slow[T](x: T, ms: int): T {.flow.} =
  delay(ms)
  result = x

proc par(): string {.flow.} =
  let a = go slow("a", 30)
  let b = go slow(2, 10)
  let c = go slow(3.5, 20)
  result = await(a) & $await(b) & $await(c)

proc mixed[T](x: T): seq[T] {.flow.} =
  # suspends in a loop and across try/except inside a generic
  for i in 0..2:
    try:
      delay(1)
      if i == 1: raise newException(ValueError, "x")
      result.add x
    except ValueError:
      result.add x
      result.add x

var failed = 0
template check(name: string, got, want: untyped) =
  if got == want: echo "ok   ", name
  else:
    echo "FAIL ", name, ": ", got, " != ", want
    failed = 1

check "id int", id(5), 5
check "id string", id("x"), "x"
check "twice", twice(7), @[7, 7]
check "twice str", twice("a"), @["a", "a"]
check "pick", pick(1, 2, false), 2
check "typedesc", zero(int), 0
check "typedesc str", zero(string), ""
check "static", rep('x', 3), @['x', 'x', 'x']
check "typedesc param", sizes(int32), 4
check "recursive", fact(10), 3628800
check "recursive int64", fact(20'i64), 2432902008176640000'i64
check "from flow", viaGeneric(), "3s22"
check "spawned generics", run par(), "a23.5"
check "generic try/loop", run mixed("k"), @["k", "k", "k", "k"]
quit failed
