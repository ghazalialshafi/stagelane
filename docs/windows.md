# Windows

stagelane builds and runs on Windows (x64, Nim 2.2+, MinGW-w64 gcc). Everything in this
file is specific to Windows; on Linux and macOS nothing here applies and nothing in the
library behaves differently because of it.

## What was verified, and how

The test-suite and most demos were ran under windows pc and all tests passed:

| configuration | flags | result |
|---|---|---|
| single thread | `--mm:arc` | all `tests/t_*.nim` pass, including `t_net` (real Winsock sockets) |
| threads | `--threads:on --mm:atomicArc -d:flowThreads` | `t_mt`, `t_fastmt` pass |
| demos | as in `demos/run_all.sh` | all passed |

Not verified:
* address/thread sanitizers.

If something fails on your machine, please report the Nim version and the first error
line.

## Building

```
nim c -d:release --mm:arc app.nim                                   :: single thread
nim c -d:release --threads:on --mm:atomicArc -d:flowThreads app.nim :: with stagelane/exec (Pool)
```

`nim c -r tests\t_basic.nim` works as on Linux. `tests/run_all.sh` and
`demos/run_all.sh` are POSIX shell scripts: run them from Git Bash / MSYS2 (they find
`timeout`, `gtimeout` or `perl` for the per-demo time limit). `tests/run_all.sh` also builds
with AddressSanitizer/ThreadSanitizer, which MinGW does not provide; on Windows run the
tests directly with `nim c -r`, and `sh demos/run_all.sh` for the demos.


## What is different from Linux

* **The selector is `select()`.** Nim's I/O selector on Windows is its `select()` backend
  (epoll on Linux, kqueue on macOS). It only works with sockets: `waitReadable` /
  `waitWritable` and `stagelane/net` are for sockets, not files, pipes or the console. Use
  a thread (`Pool`) to wrap blocking file or console calls.
* **Socket limit.** `select()` can watch at most `FD_SETSIZE` sockets per event loop.
  Windows' default is 64, which a server with a few dozen clients exceeds (the selector
  then raises `IOSelectorsException: Maximum number of descriptors is exhausted!`). In
  Windows builds only, stagelane compiles with `FD_SETSIZE=4096`. Override with
  `-d:flowFdSetSize=N` (`64` restores the Nim default). This is a ceiling, not a
  guarantee: each poll is O(number of sockets), so very large socket counts need another
  backend (IOCP), which stagelane does not have. d12 (1000 connections) and d14 (500 concurrent
  probes) are the demos that need the raised limit; see "What was verified" for their status.
* **Timers.** The timing wheel has 1 ms resolution, but a sleeping loop wakes through
  `select()`'s timeout, and Windows' default scheduler tick is about 15.6 ms. Expect
  `delay(1)` to take longer than 1 ms on a default-configured Windows machine. (Expected
  from how Windows works; not measured natively.)
* **Threads.** Cross-thread wake-ups use Nim's `SelectEvent` (a loopback socket pair on
  Windows). A thread that has run out of work yields with `SwitchToThread` before it
  sleeps (`sched_yield` on POSIX).
* **Errors.** `stagelane/net` reads `WSAGetLastError` instead of `errno`; `WSAEWOULDBLOCK`
  covers both "would block" and "connect in progress".

## Files that touch the platform

| file | Windows-specific code |
|---|---|
| `src/stagelane/sched.nim` | `FD_SETSIZE`, `SocketHandle` for the selector, `SwitchToThread` |
| `src/stagelane/net.nim` | Winsock wrappers in place of `std/posix` |
| `src/stagelane/exec.nim` | none (uses `osYield` from `sched.nim`) |
