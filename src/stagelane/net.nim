## stagelane/net — non-blocking TCP on top of the event loop (POSIX).
import std/[posix, nativesockets, os]
import ./core, ./transform, ./sched

type
  TcpStream* = ref object
    fd*: SocketHandle
    closed: bool
    rbuf: string
  TcpListener* = ref object
    fd*: SocketHandle

proc setNonBlock(fd: SocketHandle) = fd.setBlocking(false)

proc newTcpSocket(): SocketHandle =
  createNativeSocket(nativesockets.Domain.AF_INET, nativesockets.SockType.SOCK_STREAM,
                     nativesockets.Protocol.IPPROTO_TCP)

proc resolve(host: string, port: int): ptr AddrInfo =
  getAddrInfo(host, Port(port), nativesockets.Domain.AF_INET,
              nativesockets.SockType.SOCK_STREAM, nativesockets.Protocol.IPPROTO_TCP)


proc wouldBlock(): bool =
  let e = errno
  e == EAGAIN or e == EWOULDBLOCK or e == EINTR

proc listenTcp*(port: int, host = "0.0.0.0", backlog = 128): TcpListener =
  let fd = newTcpSocket()
  if fd == osInvalidSocket: raiseOSError(osLastError())
  fd.setSockOptInt(SOL_SOCKET, SO_REUSEADDR, 1)
  var ai = resolve(host, port)
  if bindAddr(fd, ai.ai_addr, ai.ai_addrlen.SockLen) < 0:
    freeAddrInfo(ai); raiseOSError(osLastError())
  freeAddrInfo(ai)
  if posix.listen(fd, backlog.cint) < 0: raiseOSError(osLastError())
  setNonBlock(fd)
  TcpListener(fd: fd)

proc localPort*(l: TcpListener): int =
  var sa: Sockaddr_in
  var len = SockLen(sizeof(sa))
  discard posix.getsockname(l.fd, cast[ptr SockAddr](addr sa), addr len)
  int(posix.ntohs(sa.sin_port))

proc close*(l: TcpListener) = close(l.fd)

proc close*(s: TcpStream) =
  if not s.closed:
    s.closed = true
    close(s.fd)

proc accept*(l: TcpListener): TcpStream {.flow.} =
  ## wait for and accept a connection
  while true:
    var sa: Sockaddr_in
    var len = SockLen(sizeof(sa))
    let fd = posix.accept(l.fd, cast[ptr SockAddr](addr sa), addr len)
    if fd != osInvalidSocket:
      setNonBlock(fd)
      return TcpStream(fd: fd)
    if not wouldBlock(): raiseOSError(osLastError())
    waitReadable(int(l.fd))

proc connectTcp*(host: string, port: int): TcpStream {.flow.} =
  ## connect to `host:port`
  let fd = newTcpSocket()
  if fd == osInvalidSocket: raiseOSError(osLastError())
  setNonBlock(fd)
  var ai = resolve(host, port)
  let r = posix.connect(fd, ai.ai_addr, ai.ai_addrlen.SockLen)
  let e = errno
  freeAddrInfo(ai)
  if r < 0 and e != EINPROGRESS:
    close(fd); raiseOSError(OSErrorCode(e))
  if r < 0:
    waitWritable(int(fd))
    var err: cint
    var len = SockLen(sizeof(err))
    discard posix.getsockopt(fd, SOL_SOCKET, SO_ERROR, addr err, addr len)
    if err != 0:
      close(fd); raiseOSError(OSErrorCode(err))
  return TcpStream(fd: fd)

proc readSome*(s: TcpStream, n: int = 4096): string {.flow.} =
  ## read up to `n` bytes; returns "" at end of stream
  if s.rbuf.len > 0:
    let k = min(n, s.rbuf.len)
    result = s.rbuf[0..<k]
    s.rbuf = s.rbuf[k..^1]
    return
  var buf = newString(n)
  while true:
    let r = posix.recv(s.fd, addr buf[0], n, 0)
    if r >= 0:
      buf.setLen(r)
      return buf
    if not wouldBlock(): raiseOSError(osLastError())
    waitReadable(int(s.fd))

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
      let r = posix.recv(s.fd, addr buf[0], 4096, 0)
      if r >= 0: got = r
      elif not wouldBlock(): raiseOSError(osLastError())
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
    let r = posix.send(s.fd, unsafeAddr data[off], data.len - off, MSG_NOSIGNAL)
    if r >= 0: off += r
    elif wouldBlock(): waitWritable(int(s.fd))
    else: raiseOSError(osLastError())
