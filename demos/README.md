# stagelane demos — 20 programs that show off concurrency

Twenty runnable programs for [stagelane](../README.md). Every demo is self-checking (it asserts its own result), so a
green run means the concurrency behaved correctly — not just that it didn't crash.

```sh
./run_all.sh                 # build + run all 20, print a PASS/FAIL table
./run_all.sh 05 12 19        # run only some
VERBOSE=1 ./run_all.sh       # also show each demo's output
NIM=/path/to/nim ./run_all.sh
```

Requires Nim 2.2+. Demos 19 and 20 use the thread pool; `run_all.sh` detects that
(they import `stagelane/exec`) and builds them with
`--threads:on --mm:atomicArc -d:flowThreads`. Everything else builds with `--mm:arc`.
To run one by hand:

```sh
nim c -d:danger --path:../src -r d01_parallel_fetch.nim
nim c -d:danger --threads:on --mm:atomicArc -d:flowThreads --path:../src -r d19_offload_blocking.nim
```

## The demos

Headline numbers are from a real run on a **1-core** sandbox (Nim 2.2.12, `-d:danger`).

### Speed and scale
| # | Demo | What it shows | Result |
|---|------|---------------|--------|
| 01 | `d01_parallel_fetch` | 100 "API calls" of 30 ms: sequential vs `go`/`await` | 3039 ms → **30 ms** (x101) |
| 02 | `d02_hundred_thousand_tasks` | 100,000 simultaneously parked tasks on one thread | spawned in **14 ms**, all done in 174 ms |
| 03 | `d03_worker_pool` | 8 workers over a `Chan`, 200 jobs | 254 ms (ideal 250), perfectly balanced 25/worker |
| 04 | `d04_pipeline_backpressure` | 4-stage pipeline, bounded channels, fan-out/fan-in | 264 ms vs ~1000 ms with one enricher |

### Resilience and control flow
| # | Demo | What it shows | Result |
|---|------|---------------|--------|
| 05 | `d05_rate_limiter` | `Semaphore` caps in-flight requests | 60 requests, peak exactly 5, 242 ms (ideal 240) |
| 06 | `d06_retry_backoff` | `withTimeout` + exponential back-off on flaky services | 20/20 succeed through 8 timeouts and 10 errors |
| 07 | `d07_hedged_requests` | first-result-wins, cancel the losers | fastest replica wins; all 10 losers cleaned up |
| 08 | `d08_structured_cancellation` | `scope`: one failure cancels siblings, `finally` runs | aborts in **30 ms** instead of 5000 ms |
| 09 | `d09_timeout_budget` | one 100 ms deadline across 3 stages | slow requests cut off exactly at the deadline |
| 10 | `d10_pubsub_broker` | pub/sub with `select` + timeout, per-subscriber channels | 21 published → 36 deliveries, all counted |

### Networking (non-blocking TCP, everything on one thread)
| # | Demo | What it shows | Result |
|---|------|---------------|--------|
| 11 | `d11_chat_server` | chat room: task per connection + writer task per client | 6 bots, all 150 broadcast lines delivered |
| 12 | `d12_echo_loadtest` | 1,000 concurrent connections × 20 round-trips, server + clients in one process | 20,000/20,000 verified, ~54k round-trips/s |
| 13 | `d13_mini_redis` | Redis-like `SET/GET/INCR/DEL/EXPIRE` server | 50 clients × 100 `INCR` = exactly 5000, TTL via timer task |
| 14 | `d14_port_scanner` | 500-way concurrent scanner with per-probe timeouts | scans ~12k ports in ~130 ms, finds all 7 planted listeners |

### Synchronisation, scheduling, threads
| # | Demo | What it shows | Result |
|---|------|---------------|--------|
| 15 | `d15_dining_philosophers` | `Mutex`; the runtime **detects** the classic deadlock | naive → `DeadlockError`; ordered → 200 meals, 0 violations |
| 16 | `d16_bank_transfers` | a race that exists even with cooperative tasks (pause between read and write) | unsafe drifts (−38); `Mutex` version exact |
| 17 | `d17_web_crawler` | 40 fetchers, unbounded frontier, `WaitGroup` completion | 3000 pages in 0.8 s vs ~30 s sequential (x37) |
| 18 | `d18_job_scheduler` | periodic jobs, per-job watchdog via `select` timeout, `Event` shutdown | detects the stalled job, clean joined shutdown |
| 19 | `d19_offload_blocking` | blocking code on a `Pool` vs on the event loop | loop frozen **411 ms** when blocking; **10 ms** gap offloaded, 8 queries in 50 ms |
| 20 | `d20_mapreduce_wordcount` | map-reduce over `SharedChan` + `Pool` threads | 2.56M words, result identical to sequential count |

**Note on 20:** speedup scales with CPU cores. The sandbox had one, so it measured
~1x (136 ms vs 147 ms); the point there is correct cross-thread data flow. On a
multi-core machine, run it and watch the ratio grow.

## Feature coverage

| stagelane feature | demos |
|---|---|
| `{.flow.}`, `delay`, `go` / `await`, `run` | all |
| `scope` (structured concurrency) | 02–05, 06, 08, 10, 11, 12, 13, 14, 16, 17, 18 |
| `cancel`, `CancelledError`, cleanup via `finally` | 07, 08, 11, 12, 13 |
| `withTimeout` / `TimeoutError` | 06, 09, 14 |
| `Chan` (bounded/unbounded), `recvOpt`, `close` | 03, 04, 07, 10, 17, 18 |
| `select` with `recv` / `timeout` | 10, 18 |
| `Mutex` / `withLock` | 15, 16 |
| `Semaphore` / `withPermit` | 05, 14 |
| `Event`, `WaitGroup` | 17, 18, 19 |
| TCP (`listenTcp`, `accept`, `connectTcp`, `readLine`, `write`) | 11, 12, 13, 14 |
| `Pool`, `pool.go`, `SharedChan` | 19, 20 |
| `DeadlockError` detection | 15 |
