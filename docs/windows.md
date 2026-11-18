# Windows

stagelane builds and runs on Windows (x64, Nim 2.2+, MinGW-w64 gcc). Everything in this
file is specific to Windows; on Linux and macOS nothing here applies and nothing in the
library behaves differently because of it.

## What was verified, and how

The test-suite and most demos were cross-compiled with MinGW-w64 on Linux and executed as
real Windows binaries under Wine, in both configurations:

| configuration | flags | result |
|---|---|---|
| single thread | `--mm:arc` | all `tests/t_*.nim` pass, including `t_net` (real Winsock sockets) |
| threads | `--threads:on --mm:atomicArc -d:flowThreads` | `t_mt`, `t_fastmt` pass |
| sockets | `--mm:arc` | `t_netfast` (idle waits, 8 MB transfer with backpressure, 3000 fd-reusing connections, EOF, cancel, connect refused, `serveTcp`) passes |
| demos | as in `demos/run_all.sh` | d01-d11 and d15-d19 pass |

Not verified:

* a native (non-Wine) Windows run of the whole suite;
* demos d12, d13, d14 (many sockets) and d20 (threads): under Wine they did not finish
  (d12/d13 timed out, d14 hit the descriptor limit before it was raised, and a later
  retry of d12/d20 hung the Wine process itself). Whether that is Wine, the 64-socket
  default, or a real problem on Windows was not determined, so treat these four as
  untested on Windows;
* address/thread sanitizers (MinGW gcc has neither).

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

Cross-compiling from Linux (what the checks above used):

```
nim c --os:windows --cpu:amd64 --gcc.exe:x86_64-w64-mingw32-gcc \
      --gcc.linkerexe:x86_64-w64-mingw32-gcc --mm:arc -o:app.exe app.nim
wine app.exe
```

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
* **Failed connects.** Winsock reports a failed non-blocking `connect` only in the
  exception set of `select()`, which Nim's selector does not look at; `connectTcp` polls the
  outcome itself (zero-timeout `select`, 1 ms between polls) so a refused connection raises
  instead of waiting forever.
* **Errors.** `stagelane/net` reads `WSAGetLastError` instead of `errno`; `WSAEWOULDBLOCK`
  covers both "would block" and "connect in progress".

## Linux-only features

`ringEnable()` (io_uring) and the persistent, edge-triggered socket registration are Linux
only. On Windows and macOS `ringEnable()` returns `false`, `watchFd`/`forgetFd` do nothing,
and `stagelane/net` uses the same readiness path as before; code written against
`stagelane/uring` still compiles and runs, it just stays on the portable path.

## Files that touch the platform

| file | Windows-specific code |
|---|---|
| `src/stagelane/sched.nim` | `FD_SETSIZE`, `SocketHandle` for the selector, `SwitchToThread` |
| `src/stagelane/net.nim` | Winsock wrappers in place of `std/posix` |
| `src/stagelane/exec.nim` | none (uses `osYield` from `sched.nim`) |
