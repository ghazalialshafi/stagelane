## stagelane/sched — tasks, the event loop, timers, parking, cancellation and
## structured concurrency on top of the continuation core.
import ./core, ./transform
import std/[deques, monotimes, os, macros, selectors, tables]
when flowThreads:
  import std/[locks, atomics]

when flowThreads:
  type
    SchedShared* = object
      ## the part of a scheduler other threads may touch: a mailbox of
      ## continuations plus a wake-up event
      lock: Lock
      buf: ptr UncheckedArray[pointer]
      cap, head, count: int
      wake*: SelectEvent
      stopping*: Atomic[bool]

type
  Timer* = ref object of RootObj
    at: int64                  # absolute deadline in ms (monotonic)
    next: pointer              # intrusive link inside a wheel slot
    cb: proc () {.closure.}
    leaf: pointer              # pinned continuation to resume when the timer fires
    cancelled: bool

proc `=destroy`(t: var typeof(Timer()[])) =
  if t.leaf != nil: releaseChain(t.leaf)       # the wheel was dropped with sleepers in it

type
  TimerList = object
    head, tail: pointer

  Wheel = object
    ## hierarchical timing wheel: 4 levels x 256 slots, 1 ms resolution
    now: int64
    live: int                  # armed (not cancelled, not fired) timers
    slots: array[4, array[256, TimerList]]


proc tlPush(l: var TimerList, t: sink Timer) {.inline.} =
  let p = cast[pointer](t)
  wasMoved(t)
  cast[Timer](p).next = nil
  if l.tail == nil: l.head = p else: cast[Timer](l.tail).next = p
  l.tail = p

proc tlTake(l: var TimerList): pointer {.inline.} =
  ## detach the whole list; the caller owns every element
  result = l.head
  l.head = nil
  l.tail = nil

proc tlNext(p: pointer): Timer {.inline.} =
  ## pop `p` as an owned Timer reference (no refcount change)
  copyMem(addr result, unsafeAddr p, sizeof(pointer))

proc `=destroy`(w: var Wheel) =
  for level in 0..3:
    for slot in 0..255:
      var p = w.slots[level][slot].head
      while p != nil:
        let nxt = cast[Timer](p).next
        var t = tlNext(p)       # drops the wheel's reference
        p = nxt
      w.slots[level][slot].head = nil
      w.slots[level][slot].tail = nil

proc `=copy`(dest: var Wheel, src: Wheel) {.error.}


type
  FdWait = ref object
    rd, wr: pointer            # pinned continuations waiting for readability / writability
    evs: set[Event]
    registered: bool

proc `=destroy`(f: var typeof(FdWait()[])) =
  if f.rd != nil: releaseChain(f.rd)
  if f.wr != nil: releaseChain(f.wr)

type
  CancelledError* = object of CatchableError
  DeadlockError* = object of CatchableError
  TimeoutError* = object of CatchableError

  Task*[T] = ref object of TaskBase
    when T isnot void:
      value*: T

  Scheduler* = ref object
    when flowThreads:
      shared*: ptr SchedShared
    sel: Selector[int]
    fds: Table[int, FdWait]
    fdWaiting: int
    ready: FrameList
    wheel: Wheel
    live*: int
    steps*: uint64


var theSched {.threadvar.}: Scheduler
var curTaskP {.threadvar.}: pointer
template curTask*(): TaskBase = cast[TaskBase](curTaskP)

when flowThreads:
  proc initShared(): ptr SchedShared =
    result = cast[ptr SchedShared](allocShared0(sizeof(SchedShared)))
    initLock(result.lock)
    result.cap = 64
    result.buf = cast[ptr UncheckedArray[pointer]](allocShared0(result.cap * sizeof(pointer)))
    result.wake = newSelectEvent()

  proc post*(target: ptr SchedShared, c: pointer) =
    ## hand a pinned continuation to the scheduler that owns `target` (any thread)
    withLock target.lock:
      if target.count == target.cap:
        let ncap = target.cap * 2
        let nb = cast[ptr UncheckedArray[pointer]](allocShared0(ncap * sizeof(pointer)))
        for i in 0..<target.count:
          nb[i] = target.buf[(target.head + i) mod target.cap]
        deallocShared(target.buf)
        target.buf = nb; target.cap = ncap; target.head = 0
      target.buf[(target.head + target.count) mod target.cap] = c
      inc target.count
    target.wake.trigger()

proc initSched() {.noinline.} =
  if theSched == nil:
    theSched = Scheduler()
    when flowThreads:
      theSched.shared = initShared()
      theSched.sel = newSelector[int]()
      theSched.sel.registerEvent(theSched.shared.wake, 0)

template sched*(): Scheduler =
  ## the scheduler of this thread (borrowed: no refcount traffic)
  if theSched == nil: initSched()
  theSched

when flowThreads:
  proc drainInbox(s: Scheduler) =
    let sh = s.shared
    withLock sh.lock:
      while sh.count > 0:
        s.ready.addLast sh.buf[sh.head]
        sh.head = (sh.head + 1) mod sh.cap
        dec sh.count

proc nowNs*(): int64 = getMonoTime().ticks
proc nowMs(): int64 {.inline.} = getMonoTime().ticks div 1_000_000

proc newWaitQueue*(): WaitQueue =
  result = WaitQueue()
  when flowThreads: initLock(result.lock)

template qlock(q: WaitQueue, body: untyped) =
  when flowThreads:
    withLock q.lock: body
  else:
    body

proc schedule*(c: pointer) =
  ## queue a pinned continuation (routed to its owning thread when needed)
  when flowThreads:
    let s {.cursor.} = sched()
    let t = envOf(c).task
    if t != nil and t.sched != nil and t.sched != cast[pointer](s.shared):
      post(cast[ptr SchedShared](t.sched), c)
      return
    s.ready.addLast c
  else:
    sched().ready.addLast c

proc newCancelled*(): ref CancelledError =
  newException(CancelledError, "task cancelled")

proc checkpoint*() =
  ## cooperative cancellation point for non-suspending loops
  if curTaskP != nil and curTask.cancelRequested: raise newCancelled()

proc wake*(c: pointer) {.inline.} =
  ## resume a parked (pinned) continuation
  let t = envOf(c).task
  if t != nil:
    t.parked = nil
    t.parkKind = pkNone
  schedule(c)

# --- timers ----------------------------------------------------------------

proc wheelAdd(w: var Wheel, t: sink Timer) =
  if t.at <= w.now: t.at = w.now + 1
  let d = t.at - w.now
  var level = 0
  while level < 3 and d >= (1'i64 shl (8 * (level + 1))): inc level
  w.slots[level][int((t.at shr (8 * level)) and 255)].tlPush t

proc fireOrReplace(w: var Wheel, p: pointer, fire: bool) =
  var cur = p
  while cur != nil:
    let nxt = cast[Timer](cur).next
    var t = tlNext(cur)
    t.next = nil
    cur = nxt
    if t.cancelled: continue
    if fire and t.at <= w.now:
      dec w.live
      t.cancelled = true            # fired: a later `cancel` must not count again
      if t.leaf != nil:
        let lf = t.leaf
        t.leaf = nil
        wake(lf)
      elif t.cb != nil:
        let cb = t.cb
        t.cb = nil
        cb()
    else:
      wheelAdd(w, t)

proc cascade(w: var Wheel, level: int) =
  let idx = int((w.now shr (8 * level)) and 255)
  let p = w.slots[level][idx].tlTake
  if idx == 0 and level < 3: cascade(w, level + 1)
  fireOrReplace(w, p, false)

proc wheelAdvance(w: var Wheel, to: int64) =
  while w.now < to:
    inc w.now
    let s0 = int(w.now and 255)
    if s0 == 0: cascade(w, 1)
    if w.slots[0][s0].head != nil:
      let p = w.slots[0][s0].tlTake
      fireOrReplace(w, p, true)
    if w.live == 0:
      w.now = to          # nothing armed: skip the rest
      break

proc wheelNextWake(w: Wheel): int =
  ## ms until the earliest armed timer may expire (conservative); -1 if none
  if w.live == 0: return -1
  for i in 1..256:
    if w.slots[0][int((w.now + i) and 255)].head != nil: return i
  for level in 1..3:
    for i in 1..256:
      let idx = int(((w.now shr (8 * level)) + i) and 255)
      if w.slots[level][idx].head != nil:
        let start = (((w.now shr (8 * level)) + i) shl (8 * level))
        return int(max(1'i64, start - w.now))
  1

proc newTimerAt(ms: int): Timer =
  let s {.cursor.} = sched()
  if s.wheel.live == 0 and s.wheel.now < nowMs(): s.wheel.now = nowMs()
  result = Timer(at: nowMs() + max(ms, 1))
  inc s.wheel.live

proc addTimer*(ms: int, cb: proc () {.closure.}): Timer =
  result = newTimerAt(ms)
  result.cb = cb
  sched().wheel.wheelAdd result

proc addLeafTimer(ms: int, leaf: pointer): Timer =
  result = newTimerAt(ms)
  result.leaf = leaf
  sched().wheel.wheelAdd result

proc cancel*(t: Timer) =
  if t != nil and not t.cancelled:
    t.cancelled = true
    t.cb = nil
    t.leaf = nil
    dec sched().wheel.live

# --- parking -----------------------------------------------------------------
# A suspension primitive is a *hook*: `proc (c: Frame, ..): Hop`.  `c` is
# the continuation that suspends (the caller itself -- nothing is allocated).
# It already carries a pin; the hook either keeps that pin somewhere (queue,
# timer, fd table) and returns `noStep`, or returns a step to continue at once.

template cancelGuard(c: Frame) =
  if c.task != nil and c.task.cancelRequested:
    c.ex = newCancelled()
    return step(cast[pointer](c))

template markParked(c: Frame, kind: ParkKind) =
  let t = c.task
  if t != nil:
    t.parked = cast[pointer](c)
    t.parkKind = kind

type
  AnyState = ref object of RootObj
    fired: bool
    target: pointer              # the pin of the waiting continuation
    qs: seq[WaitQueue]
  AnyProxy = ref object of Frame
    st: AnyState

proc `=destroy`(a: var typeof(AnyState()[])) =
  if a.target != nil: releaseChain(a.target)

proc anyProxyStage(p: pointer): Hop = noStep
let anyProxyFn = stageFn(anyProxyStage)

proc removeWaiter(q: WaitQueue, c: pointer): bool =
  qlock q:
    result = q.waiters.remove(c)

proc removeAny(q: WaitQueue, st: AnyState) =
  qlock q:
    var p = q.waiters.head
    while p != nil:
      let nxt = envOf(p).next
      if envOf(p).fn == anyProxyFn and AnyProxy(envOf(p)).st == st:
        if q.waiters.remove(p): release(p)      # proxies own their pin
      p = nxt

proc fireAny(st: AnyState, via: WaitQueue) =
  let target = st.target
  st.target = nil
  let qs = move st.qs
  for q2 in qs:
    if q2 != via: removeAny(q2, st)
  wake(target)

proc notifyOne*(q: WaitQueue): bool {.discardable.} =
  var w: pointer = nil
  qlock q:
    inc q.epoch
    while q.waiters.len > 0:
      let cand = q.waiters.popFirst
      if envOf(cand).fn == anyProxyFn:
        let st = AnyProxy(envOf(cand)).st
        if st.fired:                 # stale entry of an already woken `waitAny`
          release(cand)
          continue
        st.fired = true
      w = cand
      break
  if w == nil: return false
  if envOf(w).fn == anyProxyFn:
    let st = AnyProxy(envOf(w)).st
    release(w)
    fireAny(st, q)
  else: wake(w)
  result = true

proc notifyAll*(q: WaitQueue) =
  while notifyOne(q): discard

proc epochOf*(q: WaitQueue): int =
  qlock q:
    result = q.epoch

proc parkHook*(c: Frame, q: WaitQueue): Hop =
  cancelGuard(c)
  let p = cast[pointer](c)
  let t = c.task
  if t != nil:
    t.parked = p; t.parkKind = pkQueue; t.parkQ = cast[pointer](q)
  qlock q:
    q.waiters.addLast p
  noStep

proc parkSinceHook*(c: Frame, q: WaitQueue, since: int): Hop =
  cancelGuard(c)
  let p = cast[pointer](c)
  var stale = false
  let t = c.task
  if t != nil:
    t.parked = p; t.parkKind = pkQueue; t.parkQ = cast[pointer](q)
  qlock q:
    if q.epoch != since: stale = true
    else: q.waiters.addLast p
  if stale:
    if t != nil: (t.parked = nil; t.parkKind = pkNone)
    return step(p)
  noStep

proc parkPendingHook*(c: Frame, target: TaskBase): Hop =
  cancelGuard(c)
  if target.doneq == nil: target.doneq = newWaitQueue()
  let q {.cursor.} = target.doneq
  let p = cast[pointer](c)
  let t = c.task
  if t != nil:
    t.parked = p; t.parkKind = pkQueue; t.parkQ = cast[pointer](q)
  var finished = false
  qlock q:
    if target.state != tsPending: finished = true
    else: q.waiters.addLast p
  if finished:
    if t != nil: (t.parked = nil; t.parkKind = pkNone)
    return step(p)
  noStep

proc parkAnyHook*(c: Frame, qs: seq[WaitQueue]): Hop =
  cancelGuard(c)
  let p = cast[pointer](c)
  let t = c.task
  let st = AnyState(target: p, qs: qs)
  if t != nil:
    t.parked = p; t.parkKind = pkAny; t.parkRef = cast[pointer](st)
  for q in qs:
    let proxy = pin(AnyProxy(fn: anyProxyFn, st: st))
    qlock q:
      q.waiters.addLast proxy
  noStep

proc sleepHook*(c: Frame, ms: int): Hop =
  cancelGuard(c)
  let p = cast[pointer](c)
  if ms <= 0: return step(p)
  let t = c.task
  let tm = addLeafTimer(ms, p)
  if t != nil:
    t.parkKind = pkTimer; t.parkRef = cast[pointer](tm)
    t.parked = p
  noStep

proc yieldHook*(c: Frame): Hop =
  cancelGuard(c)
  schedule(cast[pointer](c))
  noStep

# --- the stubs (also usable outside flow procs through `blockOn`) ------------
# `blockOn` needs a continuation object: a tiny leaf that runs the hook with
# itself as the suspended continuation and finishes when resumed.

proc doneStage(p: pointer): Hop =
  if envOf(p).ex != nil: raise popEx(envOf(p))
  finish(p)

type
  PrimLeaf = ref object of Frame
    q: WaitQueue
    n: int
    tgt: TaskBase
    qs: seq[WaitQueue]

proc leafPark(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; parkHook(c, c.q)
proc leafSince(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; parkSinceHook(c, c.q, c.n)
proc leafPending(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; parkPendingHook(c, c.tgt)
proc leafAny(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; parkAnyHook(c, c.qs)
proc leafSleep(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; sleepHook(c, c.n)
proc leafYield(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; yieldHook(c)

proc parkCtor(q: WaitQueue): Frame = PrimLeaf(fn: leafPark, q: q)
proc parkSinceCtor(q: WaitQueue, since: int): Frame =
  PrimLeaf(fn: leafSince, q: q, n: since)
proc parkPendingCtor(target: TaskBase): Frame = PrimLeaf(fn: leafPending, tgt: target)
proc parkAnyCtor(qs: seq[WaitQueue]): Frame = PrimLeaf(fn: leafAny, qs: qs)
proc sleepCtor(ms: int): Frame = PrimLeaf(fn: leafSleep, n: ms)
proc yieldCtor(): Frame = PrimLeaf(fn: leafYield)

proc park*(q: WaitQueue) {.flowCtor: parkCtor, inlineSuspend: parkHook.} =
  ## suspend the calling flow proc until `notifyOne`/`notifyAll` wakes it
  blockOn(parkCtor(q))
proc parkSince*(q: WaitQueue, since: int) {.flowCtor: parkSinceCtor, inlineSuspend: parkSinceHook.} =
  ## like `park`, but returns immediately when `q.epoch != since` -- the
  ## lost-wakeup-free pattern for state shared between threads
  blockOn(parkSinceCtor(q, since))
proc parkPending*(target: TaskBase) {.flowCtor: parkPendingCtor, inlineSuspend: parkPendingHook.} =
  blockOn(parkPendingCtor(target))
proc waitAny*(qs: seq[WaitQueue]) {.flowCtor: parkAnyCtor, inlineSuspend: parkAnyHook.} =
  ## suspend until *any* of the queues notifies us
  blockOn(parkAnyCtor(qs))
proc delay*(ms: int) {.flowCtor: sleepCtor, inlineSuspend: sleepHook.} =
  ## suspend for `ms` milliseconds
  blockOn(sleepCtor(ms))
proc yieldNow*() {.flowCtor: yieldCtor, inlineSuspend: yieldHook.} =
  ## let other tasks run
  blockOn(yieldCtor())

# --- fd readiness ----------------------------------------------------------

proc syncFd(s: Scheduler, fd: int, st: FdWait) =
  let want = st.evs
  if want == {}:
    if st.registered:
      s.sel.unregister(fd.cint)
      st.registered = false
    s.fds.del fd
  elif not st.registered:
    s.sel.registerHandle(fd.cint, want, 0)
    st.registered = true
  else:
    s.sel.updateHandle(fd.cint, want)

proc dropFdWaiter(fd: int, write: bool) =
  let s {.cursor.} = sched()
  if fd in s.fds:
    let st = s.fds[fd]
    if write:
      if st.wr != nil: dec s.fdWaiting
      st.wr = nil; st.evs.excl Event.Write
    else:
      if st.rd != nil: dec s.fdWaiting
      st.rd = nil; st.evs.excl Event.Read
    s.syncFd(fd, st)

proc ioHook(c: Frame, fd: int, write: bool): Hop =
  cancelGuard(c)
  let p = cast[pointer](c)
  let s {.cursor.} = sched()
  if s.sel == nil: s.sel = newSelector[int]()
  let st = s.fds.mgetOrPut(fd, FdWait())
  if (write and st.wr != nil) or (not write and st.rd != nil):
    c.ex = newException(IOError, "another task already waits on this fd")
    return step(p)
  let t = c.task
  if t != nil:
    t.parked = p; t.parkKind = pkFd; t.parkFd = int32(fd); t.parkWrite = write
  if write: (st.wr = p; st.evs.incl Event.Write)
  else: (st.rd = p; st.evs.incl Event.Read)
  inc s.fdWaiting
  s.syncFd(fd, st)
  noStep

proc readHook*(c: Frame, fd: int): Hop = ioHook(c, fd, false)
proc writeHook*(c: Frame, fd: int): Hop = ioHook(c, fd, true)

proc leafRead(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; readHook(c, c.n)
proc leafWrite(p: pointer): Hop =
  let c = cast[PrimLeaf](p)
  c.fn = doneStage; writeHook(c, c.n)
proc readCtor(fd: int): Frame = PrimLeaf(fn: leafRead, n: fd)
proc writeCtor(fd: int): Frame = PrimLeaf(fn: leafWrite, n: fd)

proc waitReadable*(fd: int) {.flowCtor: readCtor, inlineSuspend: readHook.} =
  ## suspend until `fd` is readable (or hung up)
  blockOn(readCtor(fd))

proc waitWritable*(fd: int) {.flowCtor: writeCtor, inlineSuspend: writeHook.} =
  ## suspend until `fd` is writable
  blockOn(writeCtor(fd))

proc pollIo(s: Scheduler, timeoutMs: int) =
  if s.sel == nil: return
  let evs = s.sel.select(timeoutMs)
  for k in evs:
    let fd = k.fd
    if fd notin s.fds: continue
    let st = s.fds[fd]
    let bad = Event.Error in k.events
    if (Event.Read in k.events or bad or Event.User in k.events) and st.rd != nil:
      let leaf = st.rd
      st.rd = nil; st.evs.excl Event.Read; dec s.fdWaiting
      wake(leaf)
    if (Event.Write in k.events or bad) and st.wr != nil:
      let leaf = st.wr
      st.wr = nil; st.evs.excl Event.Write; dec s.fdWaiting
      wake(leaf)
    s.syncFd(fd, st)

# --- tasks -----------------------------------------------------------------

proc finishTask(t: TaskBase, st: TaskState, err: ref Exception) =
  when flowThreads:
    qlock t.doneq:
      t.err = err
      t.state = st
  else:
    t.err = err
    t.state = st
  t.parked = nil
  t.parkKind = pkNone
  dec sched().live
  if t.doneq != nil: notifyAll(t.doneq)
  if t.grp != nil:
    let g = t.grp
    t.grp = nil                       # break the scope <-> task cycle
    if st == tsFailed and g.failed == nil: g.failed = t
    notifyAll(g.ev)

proc completerStage(p: pointer): Hop =
  let t = cast[TaskBase](p)
  if t.ex != nil:
    let e = popEx(t)
    finishTask(t, (if e of CancelledError: tsCancelled else: tsFailed), e)
  else:
    finishTask(t, tsDone, nil)
  release(p)                  # the pin taken at launch; handles keep the task alive
  noStep

proc prepareLaunch(c: Frame, t: TaskBase): pointer =
  ## returns the pin of the root continuation; the task is pinned too
  when flowThreads: t.doneq = newWaitQueue()     # shared between threads: eager
  c.task = t
  t.fn = completerStage
  t.task = t
  var tp = t                                       # +1 owned by the root's `caller`
  c.caller = pin(tp)
  result = pin(c)

proc launch*(c: sink Frame, t: TaskBase) =
  let p = prepareLaunch(c, t)
  when flowThreads: t.sched = cast[pointer](sched().shared)
  else: t.sched = cast[pointer](sched())
  inc sched().live
  schedule(p)

when flowThreads:
  proc launchOn*(c: sink Frame, t: TaskBase, target: ptr SchedShared) =
    let p = prepareLaunch(c, t)
    t.sched = cast[pointer](target)
    post(target, p)

proc goImpl*[R](c: sink Frame, _: typedesc[R]): Task[R] =
  result = Task[R]()
  when R isnot void:
    c.dest = addr result.value
  launch(c, result)

macro go*(call: typed): untyped =
  ## start a flow proc as a concurrent task: `let t = go work(1, 2)`
  var cl = call
  while cl.kind in {nnkHiddenStdConv, nnkHiddenSubConv, nnkStmtList}: cl = cl[^1]
  if cl.kind notin {nnkCall, nnkCommand, nnkInfix, nnkPrefix, nnkPostfix}:
    error("go expects a call of a flow proc", call)
  let w = stubCtor(cl[0])
  if w == nil: error("`go` needs a call to a {.flow.} proc", call)
  let c = newCall(w)
  for a in normArgs(cl): c.add a
  result = newCall(bindSym"goImpl", c, newCall(ident"typeof", cl))

macro prepare*(call: typed): untyped =
  ## build the continuation for a flow call without starting it
  var cl = call
  while cl.kind in {nnkHiddenStdConv, nnkHiddenSubConv, nnkStmtList}: cl = cl[^1]
  let w = stubCtor(cl[0])
  if w == nil: error("`prepare` needs a call to a {.flow.} proc", call)
  let c = newCall(w)
  for a in normArgs(cl): c.add a
  result = c

proc cancelLocal(t: TaskBase) =
  if t.state != tsPending or t.cancelRequested: return
  t.cancelRequested = true
  if t.parked != nil:
    let leaf = t.parked           # we take over its pin
    t.parked = nil
    let kind = t.parkKind
    t.parkKind = pkNone
    case kind
    of pkQueue: discard removeWaiter(cast[WaitQueue](t.parkQ), leaf)
    of pkAny:
      let st = cast[AnyState](t.parkRef)
      st.fired = true
      for q in st.qs: removeAny(q, st)
      st.qs = @[]
      st.target = nil
    of pkTimer: cancel(cast[Timer](t.parkRef))
    of pkFd: dropFdWaiter(int(t.parkFd), t.parkWrite)
    of pkNone: discard
    envOf(leaf).ex = newCancelled()
    schedule(leaf)

when flowThreads:
  type CancelReq = ref object of Frame
    victim: TaskBase
  proc cancelReqStage(p: pointer): Hop =
    cancelLocal(cast[CancelReq](p).victim)
    release(p)
    noStep

proc cancel*(t: TaskBase) =
  ## request cancellation; the task sees `CancelledError` at its next
  ## suspension point (or `checkpoint()`). Safe to call from any thread.
  if t.state != tsPending: return
  when flowThreads:
    if t.sched != nil and t.sched != cast[pointer](sched().shared):
      post(cast[ptr SchedShared](t.sched),
           pin(CancelReq(fn: cancelReqStage, victim: t)))
      return
  cancelLocal(t)

proc done*(t: TaskBase): bool = t.state != tsPending
proc failed*(t: TaskBase): bool = t.state == tsFailed
proc cancelled*(t: TaskBase): bool = t.state == tsCancelled

proc waitDone*(t: TaskBase) {.flow.} =
  ## suspend until `t` finished (does not raise)
  while t.state == tsPending:
    parkPending(t)

proc getValue*[T](t: Task[T]): T =
  t.observed = true
  case t.state
  of tsDone:
    when T isnot void: result = t.value
  of tsPending: raise newException(ValueError, "task not finished")
  else: raise t.err

template await*[T](t: Task[T]): T =
  ## wait for a task and return its value (re-raising its exception)
  block:
    let flowT = t
    while flowT.state == tsPending: parkPending(flowT)
    getValue(flowT)

# --- event loop -------------------------------------------------------------

proc runLoop*(until: TaskBase = nil, forever = false) =
  ## drive the scheduler of this thread until `until` is finished (or, with
  ## `forever`, until it is asked to stop -- worker threads).
  let s {.cursor.} = sched()
  while true:
    when flowThreads:
      drainInbox(s)
      if forever and s.shared.stopping.load: break
    if until != nil and until.state != tsPending: break
    if s.wheel.live > 0:
      wheelAdvance(s.wheel, nowMs())
    if s.ready.len > 0:
      let n = s.ready.len
      for _ in 0..<n:
        let c = s.ready.popFirst
        curTaskP = cast[pointer](envOf(c).task)
        inc s.steps
        drive(step(c))
      curTaskP = nil
      if s.fdWaiting > 0: pollIo(s, 0)
      continue
    when flowThreads:
      # idle: block until a timer, an fd or another thread wakes us
      let wait = wheelNextWake(s.wheel)
      if until != nil or forever or s.fdWaiting > 0 or s.wheel.live > 0:
        pollIo(s, wait)
        continue
      break
    else:
      let wait = wheelNextWake(s.wheel)
      if s.fdWaiting > 0:
        pollIo(s, wait)
        continue
      if s.wheel.live > 0:
        if wait > 0: os.sleep(wait)
        continue
      break
  if until != nil and until.state == tsPending and not forever:
    let what = case until.parkKind
      of pkQueue: "a channel / lock / event that nothing can ever signal"
      of pkAny: "several events (select / any) none of which can fire"
      of pkTimer: "a timer"
      of pkFd: "a file descriptor"
      of pkNone: "nothing (it was never resumed)"
    raise newException(DeadlockError,
      "event loop ran out of work but the awaited task is still pending: it is parked on " &
      what & "; " & $s.live & " task(s) are alive and all of them are blocked, " &
      "no timer or I/O is armed")

when flowThreads:
  proc releaseSched*() =
    ## free the scheduler of the calling (worker) thread; called on thread exit
    drainPools()
    if theSched == nil: return
    let sh = theSched.shared
    theSched.sel.close()
    theSched = nil
    sh.wake.close()
    deallocShared(sh.buf)
    deinitLock(sh.lock)
    deallocShared(sh)

proc runUntilIdle*() = runLoop(nil)

proc syncRun(c: sink Frame) {.nimcall.} =
  let t = TaskBase()
  launch(c, t)
  runLoop(t)
  if t.state == tsFailed or t.state == tsCancelled: raise t.err

syncDriver = syncRun

proc runTask*[T](t: Task[T]): T =
  when flowThreads:
    # `t` may live on another thread: wait through a local task so that its
    # completion wakes this scheduler
    let w = goImpl(parkPendingCtor(t), void)
    runLoop(w)
    discard w
  else:
    runLoop(t)
  getValue(t)

macro run*(call: typed): untyped =
  ## run a flow proc to completion on the event loop and return its result
  var cl = call
  while cl.kind in {nnkHiddenStdConv, nnkHiddenSubConv, nnkStmtList}: cl = cl[^1]
  let sp = newCall(bindSym"go", cl)
  result = newCall(bindSym"runTask", sp)

# --- structured concurrency ------------------------------------------------

type
  Scope* = ref object of GroupBase
    tasks: seq[TaskBase]

proc newScope*(): Scope = Scope(ev: newWaitQueue())

proc add*(g: Scope, t: TaskBase) =
  g.tasks.add t
  if t.state == tsPending:
    # a child that finishes on this thread reports to the scope directly; one that
    # lives on another thread is simply waited for in order (see `join`)
    when flowThreads:
      if t.sched == cast[pointer](sched().shared): t.grp = g
    else:
      t.grp = g
  elif t.state == tsFailed and g.failed == nil:
    g.failed = t

proc cancel*(g: Scope) =
  for t in g.tasks: cancel(t)

template go*(g: Scope, call: untyped): untyped =
  ## go `call` as a child of the group
  let flowChild = go call
  g.add flowChild
  flowChild

proc joinQuiet*(g: Scope) {.flow.} =
  ## wait for every child; never raises
  var i = 0
  while i < g.tasks.len:
    waitDone(g.tasks[i])
    inc i

proc join*(g: Scope) {.flow.} =
  ## wait for all children. The first failure (in time, not in spawn order) cancels
  ## the rest (fail-fast) and is re-raised once every child has stopped.
  var i = 0
  var err: ref Exception = nil
  while i < g.tasks.len:
    let t = g.tasks[i]
    try:
      if err == nil:
        while t.state == tsPending and g.failed == nil:
          park(g.ev)
      else:
        waitDone(t)
    except CancelledError:
      g.cancel()
      joinQuiet(g)
      raise
    if err == nil and g.failed != nil:
      err = g.failed.err
      g.failed.observed = true
      g.cancel()
      continue                        # now wait for `t` to stop as well
    if t.state == tsPending: continue # a child on another thread: keep waiting
    inc i
  if err != nil: raise err

template scope*(g: untyped, body: untyped) =
  ## structured concurrency scope: all tasks spawned into `g` are finished
  ## (or cancelled when the body fails) before the scope is left.
  let g = newScope()
  var flowOk = false
  try:
    body
    flowOk = true
  finally:
    if flowOk: join(g)
    else:
      g.cancel()
      joinQuiet(g)

# --- timeouts ---------------------------------------------------------------

type TimeoutFlag* = ref object
  fired*: bool
  timer*: Timer

proc startTimeout*(ms: int, q: WaitQueue): TimeoutFlag =
  let f = TimeoutFlag()
  f.timer = addTimer(ms, proc () =
    f.fired = true
    notifyAll(q))
  f

proc doneQueue*(t: TaskBase): WaitQueue =
  if t.doneq == nil: t.doneq = newWaitQueue()
  t.doneq

proc waitFor*(t: TaskBase, ms: int): bool {.flow.} =
  ## wait up to `ms` milliseconds for `t`; returns whether it finished
  let q = t.doneQueue
  let flag = startTimeout(ms, q)
  try:
    while t.state == tsPending and not flag.fired:
      park(q)
  finally:
    cancel(flag.timer)
  result = t.state != tsPending

template withTimeout*(ms: int, call: untyped): untyped =
  ## run `call` (a flow call) as a task and cancel it after `ms` milliseconds,
  ## raising `TimeoutError`
  block:
    let flowT = go call
    if not waitFor(flowT, ms):
      cancel(flowT)
      waitDone(flowT)
      raise newException(TimeoutError, "operation timed out")
    getValue(flowT)
