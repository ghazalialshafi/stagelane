import ../src/stagelane

type MyFrame = ref object of Frame

proc add1(x: int): int {.flow: MyFrame.} =
  result = x + 1

proc twice(x: int): int {.flow: MyFrame.} =
  let a = add1(x)
  let b = add1(a)
  result = b

proc loopy(n: int): int {.flow: MyFrame.} =
  var s = 0
  var i = 0
  while i < n:
    s += add1(i)
    inc i
  result = s

echo twice(5)
echo loopy(4)
