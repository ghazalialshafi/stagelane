when not defined(linux):
  echo "skipped: io_uring is Linux-only"
else:
  import ../src/stagelane/ringcore
  import std/[posix, monotimes, times]

  let r = newRing(8)
  if r == nil:
    echo "io_uring unavailable here: skipped"
    quit 0

  proc drain(r: Ring): seq[(uint64, int32)] =
    r.reap(c): result.add (c.userData, c.res)

  # 1. nop round trip, completion visible without any further syscall
  block:
    let s = r.getSqe(); s.prepNop(); s.userData = 7
    doAssert r.submit() == 1
    let got = r.drain()
    doAssert got == @[(7'u64, 0'i32)], $got
    echo "ok nop"

  # 2. send + recv on a socketpair, both submitted in ONE syscall
  block:
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    var out1 = "hello ring"
    var inb = newString(32)
    let a = r.getSqe(); a.opcode = OpSend; a.fd = sv[0]; a.`addr` = cast[uint64](addr out1[0]); a.len = uint32(out1.len); a.userData = 1
    let b = r.getSqe(); b.opcode = OpRecv; b.fd = sv[1]; b.`addr` = cast[uint64](addr inb[0]); b.len = uint32(inb.len); b.userData = 2
    doAssert r.submit(wait = true, waitNs = 1_000_000_000) >= 1
    var results: seq[(uint64, int32)]
    var tries = 0
    while results.len < 2 and tries < 100:
      results.add r.drain(); inc tries
      if results.len < 2: discard r.submit(wait = true, waitNs = 50_000_000)
    doAssert results.len == 2, $results
    for (ud, res) in results:
      doAssert res == int32(out1.len), $results
    inb.setLen(out1.len)
    doAssert inb == out1
    discard close(sv[0]); discard close(sv[1])
    echo "ok send/recv, one syscall"

  # 3. waiting with a timeout and nothing pending: returns after ~30 ms, no completion
  block:
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    var buf = newString(8)
    let b = r.getSqe(); b.opcode = OpRecv; b.fd = sv[1]; b.`addr` = cast[uint64](addr buf[0]); b.len = 8; b.userData = 9
    let t0 = getMonoTime()
    discard r.submit(wait = true, waitNs = 30_000_000)
    let ms = (getMonoTime() - t0).inMilliseconds
    doAssert ms >= 25 and ms < 500, $ms
    doAssert r.drain().len == 0
    # cancel it so the kernel stops touching `buf`
    let c = r.getSqe(); c.opcode = OpAsyncCancel; c.`addr` = 9; c.userData = 0
    discard r.submit(wait = true, waitNs = 200_000_000)
    var seen: seq[(uint64, int32)]
    for _ in 0..5:
      seen.add r.drain()
      if seen.len >= 2: break
      discard r.submit(wait = true, waitNs = 20_000_000)
    doAssert (9'u64, -125'i32) in seen, $seen          # -ECANCELED
    discard close(sv[0]); discard close(sv[1])
    echo "ok timed wait + cancel"

  # 4. ring full -> getSqe returns nil, submitting frees the slots
  block:
    var n = 0
    while true:
      let s = r.getSqe()
      if s == nil: break
      s.prepNop(); s.userData = 100 + uint64(n); inc n
    doAssert n == 8, $n
    discard r.submit()
    doAssert r.drain().len == 8
    doAssert r.getSqe() != nil
    discard r.submit()
    discard r.drain()
    echo "ok full ring"
  r.close()
  echo "all ok"
