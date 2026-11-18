## stagelane/net — non-blocking TCP on top of the event loop (POSIX and Windows).
import std/[nativesockets, os]
when defined(windows):
  import std/winlean
else:
  import std/posix
import std/macros
import ./core, ./transform, ./sched, ./uring, ./flowfn

# --- the few socket calls that differ between Winsock and POSIX ---------------
when defined(windows):
  const wsaEintr = 10004'i32
  const wsaEwouldblock = 10035'i32
  proc lastNetError(): int {.inline.} = int(wsaGetLastError())
  proc errWouldBlock(e: int): bool {.inline.} = e == wsaEwouldblock or e == wsaEintr
  proc errInProgress(e: int): bool {.inline.} = e == wsaEwouldblock     # connect() on a non-blocking socket
  proc sockListen(fd: SocketHandle, backlog: int): int {.inline.} = int(winlean.listen(fd, backlog.cint))
  proc sockName(fd: SocketHandle, sa: ptr SockAddr, len: ptr SockLen): int {.inline.} =
    int(winlean.getsockname(fd, sa, len))
  proc sockAccept(fd: SocketHandle, sa: ptr SockAddr, len: ptr SockLen): SocketHandle {.inline.} =
    winlean.accept(fd, sa, len)
  proc sockConnect(fd: SocketHandle, sa: ptr SockAddr, len: SockLen): int {.inline.} =
    int(winlean.connect(fd, sa, len))
  proc sockRecv(fd: SocketHandle, buf: pointer, n: int): int {.inline.} =
    int(winlean.recv(fd, cast[cstring](buf), n.cint, 0))
  proc sockSend(fd: SocketHandle, buf: pointer, n: int): int {.inline.} =
    int(winlean.send(fd, cast[cstring](buf), n.cint, 0))
  proc sockPendingError(fd: SocketHandle): int {.inline.} =
    var err: cint
    var len = SockLen(sizeof(err))
    discard winlean.getsockopt(fd, SOL_SOCKET, SO_ERROR, cast[cstring](addr err), addr len)
    int(err)
  proc netToHostPort(p: uint16): int {.inline.} = int(nativesockets.ntohs(p))
  proc winConnectState(fd: SocketHandle): int =
    ## 0 = still connecting, 1 = connected, 2 = failed (zero-timeout select incl. exceptfds)
    var wset, eset: TFdSet
    FD_ZERO(wset); FD_ZERO(eset)
    FD_SET(fd, wset); FD_SET(fd, eset)
    var tv = Timeval(tv_sec: 0, tv_usec: 0)
    let n = winlean.select(cint(1), nil, addr wset, addr eset, addr tv)
    if n <= 0: return 0
    if FD_ISSET(fd, eset) != 0: return 2
    if FD_ISSET(fd, wset) != 0: return 1
    0
else:
  proc lastNetError(): int {.inline.} = int(errno)
  proc errWouldBlock(e: int): bool {.inline.} = e == int(EAGAIN) or e == int(EWOULDBLOCK) or e == int(EINTR)
  proc errInProgress(e: int): bool {.inline.} = e == int(EINPROGRESS)
  proc sockListen(fd: SocketHandle, backlog: int): int {.inline.} = int(posix.listen(fd, backlog.cint))
  proc sockName(fd: SocketHandle, sa: ptr SockAddr, len: ptr SockLen): int {.inline.} =
    int(posix.getsockname(fd, sa, len))
  proc sockAccept(fd: SocketHandle, sa: ptr SockAddr, len: ptr SockLen): SocketHandle {.inline.} =
    posix.accept(fd, sa, len)
  proc sockConnect(fd: SocketHandle, sa: ptr SockAddr, len: SockLen): int {.inline.} =
    int(posix.connect(fd, sa, len))
  proc sockRecv(fd: SocketHandle, buf: pointer, n: int): int {.inline.} = int(posix.recv(fd, buf, n, 0))
  proc sockSend(fd: SocketHandle, buf: pointer, n: int): int {.inline.} =
    int(posix.send(fd, buf, n, MSG_NOSIGNAL))        # unchanged from before the Windows port
  proc sockPendingError(fd: SocketHandle): int {.inline.} =
    var err: cint
    var len = SockLen(sizeof(err))
    discard posix.getsockopt(fd, SOL_SOCKET, SO_ERROR, addr err, addr len)
    int(err)
  proc netToHostPort(p: uint16): int {.inline.} = int(posix.ntohs(p))

type
  TcpStream* = ref object
    fd*: SocketHandle
    closed: bool
    drained: bool       # Linux: the last read emptied the socket; wait for the next edge before reading
    rbuf: string
  TcpListener* = ref object
    fd*: SocketHandle
    ringReady: bool     # Linux/io_uring: switched to blocking mode for ring accepts

proc setNonBlock(fd: SocketHandle) = fd.setBlocking(false)

proc newTcpSocket(): SocketHandle =
  createNativeSocket(nativesockets.Domain.AF_INET, nativesockets.SockType.SOCK_STREAM,
                     nativesockets.Protocol.IPPROTO_TCP)

proc resolve(host: string, port: int): ptr AddrInfo =
  getAddrInfo(host, Port(port), nativesockets.Domain.AF_INET,
              nativesockets.SockType.SOCK_STREAM, nativesockets.Protocol.IPPROTO_TCP)


proc wouldBlock(): bool = errWouldBlock(lastNetError())

proc listenTcp*(port: int, host = "0.0.0.0", backlog = 128): TcpListener =
  let fd = newTcpSocket()
  if fd == osInvalidSocket: raiseOSError(osLastError())
  fd.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
  var ai = resolve(host, port)
  if bindAddr(fd, ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
    freeAddrInfo(ai); raiseOSError(osLastError())
  freeAddrInfo(ai)
  if sockListen(fd, backlog) < 0: raiseOSError(osLastError())
  setNonBlock(fd)
  watchFd(int(fd))
  TcpListener(fd: fd)

proc localPort*(l: TcpListener): int =
  var sa: Sockaddr_in
  var len = SockLen(sizeof(sa))
  discard sockName(l.fd, cast[ptr SockAddr](addr sa), addr len)
  netToHostPort(sa.sin_port.uint16)

proc close*(l: TcpListener) =
  forgetFd(int(l.fd))
  close(l.fd)

proc close*(s: TcpStream) =
  if not s.closed:
    s.closed = true
    forgetFd(int(s.fd))
    close(s.fd)

proc accept*(l: TcpListener): TcpStream {.flow.} =
  ## wait for and accept a connection
  when defined(linux):
    if ringActive():
      if not l.ringReady:
        l.fd.setBlocking(true)          # io_uring waits for us; a non-blocking fd would answer EAGAIN
        l.ringReady = true
      let r = ringAccept(int(l.fd))
      if r < 0: raiseOSError(OSErrorCode(-r))
      return TcpStream(fd: SocketHandle(r))   # accepted sockets start out blocking
  while true:
    var sa: Sockaddr_in
    var len = SockLen(sizeof(sa))
    let fd = sockAccept(l.fd, cast[ptr SockAddr](addr sa), addr len)
    if fd != osInvalidSocket:
      setNonBlock(fd)
      watchFd(int(fd))
      return TcpStream(fd: fd)
    if not wouldBlock(): raiseOSError(osLastError())
    waitReadable(int(l.fd))

proc connectTcp*(host: string, port: int): TcpStream {.flow.} =
  ## connect to `host:port`
  let fd = newTcpSocket()
  if fd == osInvalidSocket: raiseOSError(osLastError())
  when defined(linux):
    if ringActive():
      var rai = resolve(host, port)
      let rr = ringConnect(int(fd), rai.ai_addr, int(rai.ai_addrlen))   # blocking-mode socket
      freeAddrInfo(rai)
      if rr < 0:
        close(fd); raiseOSError(OSErrorCode(-rr))
      return TcpStream(fd: fd)
  setNonBlock(fd)
  var ai = resolve(host, port)
  let r = sockConnect(fd, ai.ai_addr, ai.ai_addrlen.SockLen)
  let e = lastNetError()
  freeAddrInfo(ai)
  if r < 0 and not errInProgress(e):
    close(fd); raiseOSError(OSErrorCode(e))
  if r < 0:
    when defined(windows):
      # Winsock reports a *failed* non-blocking connect only in select()'s exception
      # set, which Nim's selector never looks at: poll the outcome ourselves
      while true:
        let st = winConnectState(fd)
        if st != 0: break
        delay(1)
    else:
      waitWritable(int(fd))
    let err = sockPendingError(fd)
    if err != 0:
      close(fd); raiseOSError(OSErrorCode(err))
  watchFd(int(fd))
  return TcpStream(fd: fd)

proc readSome*(s: TcpStream, n: int = 4096): string {.flow.} =
  ## read up to `n` bytes; returns "" at end of stream
  if s.rbuf.len > 0:
    let k = min(n, s.rbuf.len)
    result = s.rbuf[0..<k]
    s.rbuf = s.rbuf[k..^1]
    return
  var buf = newString(n)
  when defined(linux):
    if ringActive():
      let rr = ringRecv(int(s.fd), addr buf[0], n)
      if rr < 0: raiseOSError(OSErrorCode(-rr))
      buf.setLen(rr)
      return buf
  while true:
    when defined(linux):
      if s.drained:                    # known empty: skip the probing recv that would only say EAGAIN
        waitReadable(int(s.fd))
        s.drained = false
    let r = sockRecv(s.fd, addr buf[0], n)
    if r >= 0:
      when defined(linux):
        if r > 0 and r < n: s.drained = true     # a short read means the socket is empty now
      buf.setLen(r)
      return buf
    if not wouldBlock(): raiseOSError(osLastError())
    when defined(linux): s.drained = true
    else: waitReadable(int(s.fd))

proc readLine*(s: TcpStream): string {.flow.} =
  ## read up to and excluding "\n" ("\r\n" tolerated); "" + EOF -> raises IOError
  while true:
    let i = s.rbuf.find('\n')
    if i >= 0:
      result = s.rbuf[0..<i]
      if result.len > 0 and result[^1] == '\r': result.setLen(result.len - 1)
      s.rbuf = s.rbuf[i+1..^1]
      return
    var buf = newString(4096)
    var got = -1
    while got < 0:
      when defined(linux):
        if ringActive():
          let rr = ringRecv(int(s.fd), addr buf[0], 4096)
          if rr < 0: raiseOSError(OSErrorCode(-rr))
          got = rr
          continue
        if s.drained:
          waitReadable(int(s.fd))
          s.drained = false
      let r = sockRecv(s.fd, addr buf[0], 4096)
      if r >= 0:
        got = r
        when defined(linux):
          if r > 0 and r < 4096: s.drained = true
      elif not wouldBlock(): raiseOSError(osLastError())
      else:
        when defined(linux): s.drained = true
        else: waitReadable(int(s.fd))
    if got == 0:
      if s.rbuf.len > 0:
        result = s.rbuf; s.rbuf = ""; return
      raise newException(IOError, "connection closed")
    buf.setLen(got)
    s.rbuf.add buf

proc write*(s: TcpStream, data: string) {.flow.} =
  ## write all of `data`
  var off = 0
  while off < data.len:
    when defined(linux):
      if ringActive():
        let rr = ringSend(int(s.fd), unsafeAddr data[off], data.len - off)
        if rr < 0: raiseOSError(OSErrorCode(-rr))
        off += rr
        continue
    let r = sockSend(s.fd, unsafeAddr data[off], data.len - off)
    if r >= 0: off += r
    elif wouldBlock(): waitWritable(int(s.fd))
    else: raiseOSError(osLastError())

# --- zero-copy primitives: caller-owned memory, no allocation ------------------

proc recvInto*(s: TcpStream, buf: pointer, n: int): int {.flow.} =
  ## read up to `n` bytes into `buf`; returns 0 at end of stream.  Unlike `readSome`
  ## this allocates nothing: the caller owns (and reuses) the buffer.
  if s.rbuf.len > 0:
    let k = min(n, s.rbuf.len)
    copyMem(buf, unsafeAddr s.rbuf[0], k)
    s.rbuf = s.rbuf[k..^1]
    return k
  when defined(linux):
    if ringActive():
      let rr = ringRecv(int(s.fd), buf, n)
      if rr < 0: raiseOSError(OSErrorCode(-rr))
      return rr
  while true:
    when defined(linux):
      if s.drained:
        waitReadable(int(s.fd))
        s.drained = false
    let r = sockRecv(s.fd, buf, n)
    if r >= 0:
      when defined(linux):
        if r > 0 and r < n: s.drained = true
      return r
    if not wouldBlock(): raiseOSError(osLastError())
    when defined(linux): s.drained = true
    else: waitReadable(int(s.fd))

proc sendFrom*(s: TcpStream, buf: pointer, n: int) {.flow.} =
  ## write all `n` bytes at `buf` (the memory must stay valid until this returns)
  var off = 0
  while off < n:
    when defined(linux):
      if ringActive():
        let rr = ringSend(int(s.fd), cast[pointer](cast[uint](buf) + uint(off)), n - off)
        if rr < 0: raiseOSError(OSErrorCode(-rr))
        off += rr
        continue
    let r = sockSend(s.fd, cast[pointer](cast[uint](buf) + uint(off)), n - off)
    if r >= 0: off += r
    elif wouldBlock(): waitWritable(int(s.fd))
    else: raiseOSError(osLastError())

# --- handlers by name ----------------------------------------------------------------

macro serveTcp*(l: untyped, handler: untyped, ctx: varargs[untyped]): untyped =
  ## Accept connections forever and run `handler(ctx..., conn)` as one task per connection.
  ## `handler` is the *name* of a `{.flow.}` proc whose last parameter is the `TcpStream`, so
  ## it may pause (`delay`, channels, other sockets, ...) even though flow procs cannot be stored
  ## in `proc` variables: the call is resolved at compile time.  Call it from a flow proc.
  ##
  ## `ctx` carries what the handler needs besides the connection (a server object, a
  ## config, a channel...): each is evaluated once, before the first accept, and passed in
  ## front of the connection, so `serveTcp(l, handle, app, limits)` runs `handle(app, limits, conn)`.
  ## (A `ref` object is shared by all connections; other values are copied into each task.)
  let lis = genSym(nskLet, "flowListener")
  let conn = genSym(nskLet, "flowConn")
  var lets = newStmtList()
  lets.add newLetStmt(lis, l)
  let call = newCall(handler)
  for c in ctx:
    let v = genSym(nskLet, "flowCtx")
    lets.add newLetStmt(v, c)
    call.add v
  call.add conn
  result = lets
  result.add quote do:
    while true:
      let `conn` = `lis`.accept()
      discard go `call`
  result = newBlockStmt(result)

proc serveTcp*(l: TcpListener, handler: FlowFn[proc (c: TcpStream)]) {.flow.} =
  ## Like the template above for a handler held in a value (`flowFn(myHandler)`), so a
  ## server can be written once and given its handler, or pick it from a table.
  while true:
    let conn = l.accept()
    discard go handler.call(conn)
