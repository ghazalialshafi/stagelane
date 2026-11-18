## stagelane/ringcore — a minimal io_uring wrapper (Linux), written from the kernel ABI.
##
## No scheduler knowledge here: a Ring owns the fd and the three mmaps and offers
##   getSqe   claim a submission entry (nil when the ring is full)
##   submit   publish the claimed entries; optionally also wait for a completion with a
##            timeout in the *same* syscall (io_uring_enter + EXT_ARG)
##   reap     read completions straight from shared memory: no syscall
## Completions never get lost: IORING_FEAT_NODROP is required (kernel 5.5+), as is
## EXT_ARG (5.11+), so `newRing` returns nil on anything older and callers fall back to
## epoll.

import std/posix

const
  SysSetup = 425
  SysEnter = 426
  OffSqRing = 0'u64
  OffSqes = 0x10000000'u64
  FeatSingleMmap = 1'u32
  FeatNoDrop = 2'u32
  FeatExtArg = 1'u32 shl 8
  EnterGetEvents = 1'u32
  EnterExtArg = 8'u32

  # opcodes (linux/io_uring.h)
  OpNop* = 0'u8
  OpWritev* = 2'u8
  OpSendmsg* = 9'u8
  OpLinkTimeout* = 15'u8
  SqeIoLink* = 4'u8              # sqe.flags: the next entry runs only after (and is tied to) this one
  OpPollAdd* = 6'u8
  OpAccept* = 13'u8
  OpAsyncCancel* = 14'u8
  OpConnect* = 16'u8
  OpRead* = 22'u8
  OpWrite* = 23'u8
  OpSend* = 26'u8
  OpRecv* = 27'u8
  OpClose* = 19'u8

proc rawSyscall(n: clong): clong {.importc: "syscall", header: "<unistd.h>", varargs.}

type
  SqOff = object
    head, tail, ringMask, ringEntries, flags, dropped, arr, resv1: uint32
    userAddr: uint64
  CqOff = object
    head, tail, ringMask, ringEntries, overflow, cqes, flags, resv1: uint32
    userAddr: uint64
  Params = object
    sqEntries, cqEntries, flags, sqThreadCpu, sqThreadIdle, features, wqFd: uint32
    resv: array[3, uint32]
    sqOff: SqOff
    cqOff: CqOff

  Sqe* = object
    opcode*: uint8
    flags*: uint8
    ioprio*: uint16
    fd*: int32
    off*: uint64
    `addr`*: uint64
    len*: uint32
    opFlags*: uint32
    userData*: uint64
    bufIndex: uint16
    personality: uint16
    spliceFdIn: int32
    addr3: uint64
    pad: uint64

  Cqe* = object
    userData*: uint64
    res*: int32
    flags*: uint32

  EnterArg = object
    sigmask: uint64
    sigmaskSz, minWaitUsec: uint32
    ts: uint64
  KTimespec = object
    sec, nsec: int64

  Ring* = ref object
    fd*: cint
    entries*: int
    sqMap, sqesMap: pointer
    sqMapLen, sqesMapLen: int
    cqMap: pointer                       # == sqMap with SINGLE_MMAP
    sqHead, sqTail, cqHead, cqTail: ptr uint32
    sqMask, cqMask: uint32
    sqArray: ptr UncheckedArray[uint32]
    sqes: ptr UncheckedArray[Sqe]
    cqes: ptr UncheckedArray[Cqe]
    localTail: uint32                    # next free SQ slot (not yet published)
    published: uint32                    # tail the kernel has been told about
    unsubmitted*: int                    # claimed entries the kernel has not consumed yet

static:
  doAssert sizeof(Sqe) == 64 and sizeof(Cqe) == 16 and sizeof(Params) == 120

proc ldAcq(p: ptr uint32): uint32 {.inline.} = atomicLoadN(p, ATOMIC_ACQUIRE)
proc stRel(p: ptr uint32, v: uint32) {.inline.} = atomicStoreN(p, v, ATOMIC_RELEASE)

proc newRing*(entries = 1024): Ring =
  ## nil when io_uring is unavailable (old kernel, seccomp, disabled by sysctl)
  var p: Params
  let fd = int(rawSyscall(SysSetup, clong(entries), addr p))
  if fd < 0: return nil
  if (p.features and FeatSingleMmap) == 0 or (p.features and FeatNoDrop) == 0 or
     (p.features and FeatExtArg) == 0:
    discard close(cint(fd)); return nil
  let sqLen = int(p.sqOff.arr) + int(p.sqEntries) * sizeof(uint32)
  let cqLen = int(p.cqOff.cqes) + int(p.cqEntries) * sizeof(Cqe)
  let mapLen = max(sqLen, cqLen)
  let m = mmap(nil, mapLen, PROT_READ or PROT_WRITE, MAP_SHARED or MAP_POPULATE,
               cint(fd), Off(OffSqRing))
  if m == MAP_FAILED: discard close(cint(fd)); return nil
  let sqesLen = int(p.sqEntries) * sizeof(Sqe)
  let e = mmap(nil, sqesLen, PROT_READ or PROT_WRITE, MAP_SHARED or MAP_POPULATE,
               cint(fd), Off(OffSqes))
  if e == MAP_FAILED:
    discard munmap(m, mapLen); discard close(cint(fd)); return nil
  template at(off: uint32): untyped = cast[pointer](cast[uint](m) + uint(off))
  result = Ring(fd: cint(fd), entries: int(p.sqEntries), sqMap: m, sqesMap: e,
                sqMapLen: mapLen, sqesMapLen: sqesLen, cqMap: m)
  result.sqHead = cast[ptr uint32](at(p.sqOff.head))
  result.sqTail = cast[ptr uint32](at(p.sqOff.tail))
  result.sqMask = cast[ptr uint32](at(p.sqOff.ringMask))[]
  result.sqArray = cast[ptr UncheckedArray[uint32]](at(p.sqOff.arr))
  result.sqes = cast[ptr UncheckedArray[Sqe]](e)
  result.cqHead = cast[ptr uint32](at(p.cqOff.head))
  result.cqTail = cast[ptr uint32](at(p.cqOff.tail))
  result.cqMask = cast[ptr uint32](at(p.cqOff.ringMask))[]
  result.cqes = cast[ptr UncheckedArray[Cqe]](at(p.cqOff.cqes))
  result.localTail = result.sqTail[]
  result.published = result.localTail

proc close*(r: Ring) =
  if r == nil or r.fd < 0: return
  discard munmap(r.sqesMap, r.sqesMapLen)
  discard munmap(r.sqMap, r.sqMapLen)
  discard posix.close(r.fd)
  r.fd = -1

proc getSqe*(r: Ring): ptr Sqe =
  ## claim the next submission entry, zeroed; nil when the ring is full
  if int(r.localTail - ldAcq(r.sqHead)) >= r.entries: return nil
  let idx = r.localTail and r.sqMask
  r.sqArray[idx] = idx
  result = addr r.sqes[idx]
  zeroMem(result, sizeof(Sqe))
  inc r.localTail
  inc r.unsubmitted

proc freeSlots*(r: Ring): int {.inline.} =
  ## submission entries that can be claimed right now
  r.entries - int(r.localTail - ldAcq(r.sqHead))

proc enter(r: Ring, toSubmit: int, minComplete: int, flags: uint32, arg: pointer): int =
  while true:
    let n = int(rawSyscall(SysEnter, clong(r.fd), clong(toSubmit), clong(minComplete),
                           clong(flags), arg, clong(if arg != nil: sizeof(EnterArg) else: 0)))
    if n >= 0: return n
    let e = int(errno)
    if e == int(EINTR): continue
    return -e

proc n_done(r: Ring, consumed: int) {.inline.} =
  r.unsubmitted -= consumed
  if r.unsubmitted < 0: r.unsubmitted = 0

proc submit*(r: Ring, waitNs = 0'i64, wait = false): int =
  ## Publish claimed entries.  With `wait`, block until at least one completion exists
  ## or `waitNs` elapsed (< 0: no timeout) -- in the same syscall.  Returns the
  ## number of entries the kernel consumed, or -errno.
  if r.unsubmitted == 0 and not wait: return 0
  stRel(r.sqTail, r.localTail)
  var flags = 0'u32
  var arg: EnterArg
  var ts: KTimespec
  var argp: pointer = nil
  var minC = 0
  if wait:
    flags = EnterGetEvents
    minC = 1
    if waitNs >= 0:
      ts.sec = waitNs div 1_000_000_000'i64
      ts.nsec = waitNs mod 1_000_000_000'i64
      arg.ts = cast[uint64](addr ts)
      argp = addr arg
      flags = flags or EnterExtArg
  var left = r.unsubmitted
  var total = 0
  while true:
    let n = enter(r, left, minC, flags, argp)
    if n < 0:
      if n == -int(ETIME): n_done(r, total); return total   # timed out waiting: fine
      if n == -int(EBUSY) or n == -int(EAGAIN): n_done(r, total); return total   # CQ pressure: reap first
      return n
    total += n
    left -= n
    if left <= 0 or not wait: break
    # entries remain unconsumed: submit them without waiting again
    flags = 0; argp = nil; minC = 0
  n_done(r, total)
  total

proc cqReady*(r: Ring): bool {.inline.} = ldAcq(r.cqTail) != r.cqHead[]

template reap*(r: Ring, cqe, body: untyped) =
  ## run `body` for every completion currently in the queue (no syscall); `cqe` names it
  var flowRh = r.cqHead[]
  let flowRt = ldAcq(r.cqTail)
  while flowRh != flowRt:
    let cqe {.inject.} = r.cqes[flowRh and r.cqMask]
    inc flowRh
    stRel(r.cqHead, flowRh)          # free the slot before running the handler
    body

proc prepNop*(s: ptr Sqe) = s.opcode = OpNop
