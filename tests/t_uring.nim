when not defined(linux):
  echo "skipped: io_uring is Linux-only"
else:
  import ../src/stagelane
  import ../src/stagelane/uring
  import std/[posix, os]

  if not ringEnable():
    echo "io_uring unavailable here: skipped"
    quit 0

  template check(e, v: untyped) =
    let got = e
    if got != v: echo "FAIL ", astToStr(e), ": got ", got, " want ", v; quit 1
    else: echo "ok   ", astToStr(e)

  check ringActive(), true

  proc nop3(): int {.flow.} =
    result = ringNop() + ringNop() + ringNop()
  check run nop3(), 0

  # ---- pipes and regular files (epoll cannot do files) --------------------------------------------
  proc pipeRoundTrip(): string {.flow.} =
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    var msg = "through the ring"
    let w = ringWrite(int(fds[1]), addr msg[0], msg.len)
    var buf = newString(64)
    let r = ringRead(int(fds[0]), addr buf[0], buf.len)
    buf.setLen(r)
    discard close(fds[0]); discard close(fds[1])
    $w & ":" & buf
  check run pipeRoundTrip(), "16:through the ring"

  proc fileIo(path: string): string {.flow.} =
    let fd = open(path.cstring, O_RDWR or O_CREAT or O_TRUNC, 0o600)
    var a = "0123456789"
    var b = "ABC"
    discard ringWrite(int(fd), addr a[0], a.len, 0)
    discard ringWrite(int(fd), addr b[0], b.len, 4)        # positioned: overwrite in the middle
    var buf = newString(10)
    let n = ringRead(int(fd), addr buf[0], 10, 0)
    buf.setLen(n)
    discard close(fd)
    buf
  let tmp = getTempDir() / "stagelane_uring_test.bin"
  check run fileIo(tmp), "0123ABC789"
  removeFile(tmp)

  # ---- errors are returned as -errno ------------------------------------------------------------------
  proc badFd(): int {.flow.} =
    var b = newString(4)
    ringRecv(9999, addr b[0], 4)
  check run badFd(), -int(EBADF)

  # ---- many operations in flight at once: ring bigger than one batch ----------------------------------
  proc pingN(a, b: int, n: int): int {.flow.} =
    var buf = newString(1)
    for i in 0..<n:
      var one = "x"
      discard ringSend(a, addr one[0], 1)
      result += ringRecv(b, addr buf[0], 1)       # the peer end
  proc manyPairs(): int {.flow.} =
    var ts: seq[Task[int]]
    var socks: seq[cint]
    scope g:
      for i in 0..<300:                          # 300 concurrent tasks x 2 ops > 256 default batch
        var sv: array[2, cint]
        doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
        socks.add sv[0]; socks.add sv[1]
        ts.add go(g, pingN(int(sv[0]), int(sv[1]), 20))
      for t in ts: result += await(t)
    for s in socks: discard close(s)
  check run manyPairs(), 300 * 20

  # ---- cancellation: the task resumes only after the kernel let go of the buffer ---------------------
  var cancelBufCheck = ""
  proc blockedRecv(fd: int): string {.flow.} =
    var buf = newString(16)
    try:
      discard ringRecv(fd, addr buf[0], buf.len)
      result = "completed"
    except CancelledError:
      result = "cancelled"
  proc cancelTest(): string {.flow.} =
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    let t = go blockedRecv(int(sv[1]))
    delay(10)
    t.cancel()
    result = await(t)
    # the socket is still usable afterwards
    var msg = "ok"
    discard ringSend(int(sv[0]), addr msg[0], 2)
    var b = newString(2)
    let n = ringRecv(int(sv[1]), addr b[0], 2)
    b.setLen(n)
    discard close(sv[0]); discard close(sv[1])
    result &= "/" & b
  check run cancelTest(), "cancelled/ok"

  # ---- timeouts via the normal API ---------------------------------------------------------------------
  proc timedRecv(): string {.flow.} =
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    var buf = newString(8)
    try:
      discard withTimeout(20, ringRecv(int(sv[1]), addr buf[0], 8))
      result = "no timeout"
    except TimeoutError: result = "timeout"
    discard close(sv[0]); discard close(sv[1])
  check run timedRecv(), "timeout"

  # ---- timers and ring ops share one loop ----------------------------------------------------------------
  proc ticker(n: int): int {.flow.} =
    for i in 0..<n:
      delay(2)
      inc result
  proc mixed(): int {.flow.} =
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    scope g:
      let tk = go(g, ticker(10))
      var msg = "z"
      discard ringSend(int(sv[0]), addr msg[0], 1)
      var b = newString(1)
      result = ringRecv(int(sv[1]), addr b[0], 1) + await(tk)
    discard close(sv[0]); discard close(sv[1])
  check run mixed(), 11

  # ---- per-operation deadlines: LINK_TIMEOUT --------------------------------------------------------
  proc linkTimeouts(): string {.flow.} =
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    var buf = newString(8)
    let t0 = nowNs()
    let r = ringRecv(int(sv[1]), addr buf[0], 8, timeoutMs = 30)     # nothing is coming
    let ms = (nowNs() - t0) div 1_000_000
    result = (if r == -int(ETIME): "etime" else: "res=" & $r) & (if ms >= 25 and ms < 500: ",timed" else: ",ms=" & $ms)
    # the deadline did not leave anything behind: the same socket works, with and without one
    var msg = "hi"
    discard ringSend(int(sv[0]), addr msg[0], 2, timeoutMs = 1000)
    let n = ringRecv(int(sv[1]), addr buf[0], 8, timeoutMs = 1000)   # finishes first: no ETIME
    result &= "," & $n
    let n2 = ringSend(int(sv[0]), addr msg[0], 2)
    discard n2
    let n3 = ringRecv(int(sv[1]), addr buf[0], 8)
    result &= "," & $n3
    discard close(sv[0]); discard close(sv[1])
  check run linkTimeouts(), "etime,timed,2,2"

  proc waiter(fd: int): int {.flow.} =
    var b = newString(1)
    ringRecv(fd, addr b[0], 1, timeoutMs = 10 + fd mod 7)
  proc manyTimeouts(): int {.flow.} =
    # 200 tasks each waiting with a short deadline: every one must come back with ETIME
    var ts: seq[Task[int]]
    var socks: seq[cint]
    scope g:
      for i in 0..<200:
        var sv: array[2, cint]
        doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
        socks.add sv[0]; socks.add sv[1]
        ts.add go(g, waiter(int(sv[1])))
      for t in ts: result += (if await(t) == -int(ETIME): 1 else: 0)
    for s in socks: discard close(s)
  check run manyTimeouts(), 200

  # ---- writev, sendmsg, close ----------------------------------------------------------------------------
  proc vectored(): string {.flow.} =
    var fds: array[2, cint]
    doAssert pipe(fds) == 0
    var a = "abc"
    var b = "defg"
    var iov: array[2, IOVec]
    iov[0].iov_base = addr a[0]; iov[0].iov_len = 3
    iov[1].iov_base = addr b[0]; iov[1].iov_len = 4
    let w = ringWritev(int(fds[1]), addr iov[0], 2)
    var buf = newString(16)
    let r = ringRead(int(fds[0]), addr buf[0], buf.len)
    buf.setLen(r)
    result = $w & ":" & buf
    check ringClose(int(fds[1])), 0
    check ringRead(int(fds[0]), addr buf[0], 4), 0           # writer closed: end of stream
    check ringClose(int(fds[0])), 0
    check ringClose(int(fds[0])), -int(EBADF)                # already closed
  check run vectored(), "7:abcdefg"

  proc withMsg(): string {.flow.} =
    var sv: array[2, cint]
    doAssert socketpair(AF_UNIX, SOCK_STREAM, 0, sv) == 0
    var a = "ping"
    var iov: IOVec
    iov.iov_base = addr a[0]; iov.iov_len = 4
    var mh: Tmsghdr
    mh.msg_iov = addr iov; mh.msg_iovlen = 1
    let w = ringSendmsg(int(sv[0]), addr mh)
    var buf = newString(8)
    let r = ringRecv(int(sv[1]), addr buf[0], 8)
    buf.setLen(r)
    discard close(sv[0]); discard close(sv[1])
    $w & ":" & buf
  check run withMsg(), "4:ping"

  # ---- a ring per pool worker ------------------------------------------------------------------------------
  when defined(flowThreads):
    import ../src/stagelane/exec
    import ../src/stagelane/net
    proc srv(l: TcpListener) {.flow.} =
      let c = l.accept()
      let line = c.readLine()
      c.write("echo " & line & "\n")
      c.close()
    proc ringedWorker(): string {.flow.} =
      # a complete exchange on one worker: its own ring must be active there
      if not ringActive(): return "no ring"
      let l = listenTcp(0, "127.0.0.1")
      let port = l.localPort
      scope g:
        discard go(g, srv(l))
        let c = connectTcp("127.0.0.1", port)
        c.write("worker\n")
        result = c.readLine()
        c.close()
      l.close()
    let pool = newPool(2, ring = true)
    check await(pool.go ringedWorker()), "echo worker"
    check await(pool.go ringedWorker()), "echo worker"
    proc ringOnWorker(): bool {.flow.} = ringActive()
    check await(pool.goAt(1, ringOnWorker())), true
    pool.shutdown()
    let plain = newPool(1)
    check await(plain.go ringOnWorker()), false      # default: readiness-based, as before
    plain.shutdown()
