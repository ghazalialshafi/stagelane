## stagelane/uring — completion-based I/O on io_uring (Linux 5.11+), opt-in.
##
##   if ringEnable(): echo "using io_uring"      # once per thread, before the first I/O
##
## Each call below submits ONE operation and suspends until the kernel finishes it.  All
## operations a loop turn produces go to the kernel in a single syscall, and their
## completions are read back from shared memory, so a busy server needs far fewer syscalls
## per request than readiness-style I/O (recv + EAGAIN + epoll_ctl + epoll_wait + send).
## Operations that wait on the network take an optional `timeoutMs`: the operation is linked
## to an `IORING_OP_LINK_TIMEOUT`, so the kernel itself abandons it after the deadline and the
## result is `-ETIME` (no timer in the event loop, no extra task, no cancel round trip).
## Results are the kernel's: a value >= 0, or -errno (never an exception, so a short read
## or ECONNRESET is the caller's to interpret).  Buffers are caller-owned and must stay valid
## until the call returns; if the task is cancelled while waiting, the task resumes only
## after the kernel has stopped using the buffer.
##
## Sockets used with these calls must be in *blocking* mode (io_uring waits for you):
## `stagelane/net` does that automatically once the ring is enabled.
import ./core, ./transform, ./sched

when defined(linux):
  import ./ringcore
  export ringEnable, ringActive

  const
    msgNoSignal = 0x4000'u32
    sockCloexec = 0x80000'u32

  proc ringOp(code: uint8, fd: int, buf: pointer, len: int, off: int64,
              flags: uint32, timeoutMs: int): int {.flow.} =
    let op = ringAcquire(code, fd, buf, len, off, flags, timeoutMs)
    ringWait(op)
    result = op.res
    ringRelease(op)

  proc ringRecv*(fd: int, buf: pointer, n: int, timeoutMs = 0): int {.flow.} =
    ## read up to `n` bytes; 0 means end of stream
    result = ringOp(OpRecv, fd, buf, n, 0, 0, timeoutMs)

  proc ringSend*(fd: int, buf: pointer, n: int, timeoutMs = 0): int {.flow.} =
    ## write up to `n` bytes (may be fewer); SIGPIPE is suppressed
    result = ringOp(OpSend, fd, buf, n, 0, msgNoSignal, timeoutMs)

  proc ringAccept*(fd: int, timeoutMs = 0): int {.flow.} =
    ## accept one connection from a listening socket; the new fd (close-on-exec)
    result = ringOp(OpAccept, fd, nil, 0, 0, sockCloexec, timeoutMs)

  proc ringConnect*(fd: int, sockaddr: pointer, addrLen: int, timeoutMs = 0): int {.flow.} =
    ## connect a (blocking-mode) socket; 0 on success
    result = ringOp(OpConnect, fd, sockaddr, 0, int64(addrLen), 0, timeoutMs)

  proc ringRead*(fd: int, buf: pointer, n: int, offset: int64 = -1, timeoutMs = 0): int {.flow.} =
    ## read from a file or pipe; `offset` -1 = the current position.  Unlike epoll this
    ## also works for regular files.
    result = ringOp(OpRead, fd, buf, n, offset, 0, timeoutMs)

  proc ringWrite*(fd: int, buf: pointer, n: int, offset: int64 = -1, timeoutMs = 0): int {.flow.} =
    ## write to a file or pipe; `offset` -1 = the current position
    result = ringOp(OpWrite, fd, buf, n, offset, 0, timeoutMs)

  proc ringWritev*(fd: int, iov: pointer, count: int, offset: int64 = -1, timeoutMs = 0): int {.flow.} =
    ## gather write: `iov` points to `count` `IOVec`s (all of them stay valid until return)
    result = ringOp(OpWritev, fd, iov, count, offset, 0, timeoutMs)

  proc ringSendmsg*(fd: int, msg: pointer, timeoutMs = 0): int {.flow.} =
    ## `sendmsg(2)`: `msg` points to a `Tmsghdr` (and what it references, all valid until return)
    result = ringOp(OpSendmsg, fd, msg, 1, 0, msgNoSignal, timeoutMs)

  proc ringClose*(fd: int): int {.flow.} =
    ## close a descriptor through the ring (0 or -errno)
    result = ringOp(OpClose, fd, nil, 0, 0, 0, 0)

  proc ringNop*(): int {.flow.} =
    ## a round trip through the kernel (useful for benchmarks and tests)
    result = ringOp(OpNop, -1, nil, 0, 0, 0, 0)
else:
  proc ringEnable*(entries = 1024): bool = false
  proc ringActive*(): bool = false
