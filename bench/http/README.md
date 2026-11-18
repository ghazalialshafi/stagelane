# HTTP / socket benchmark

The scheduler benchmarks in `../compare` are all in-memory. A server spends its time in
syscalls, which they cannot show, so this one drives real sockets: an HTTP hello server
(stagelane in three I/O modes, Go `net/http` for scale) against a Go load generator, with
64 keep-alive connections, in three traffic shapes.

```
sh run.sh
```

| shape | what it exercises |
|---|---|
| `busy` | keep-alive, requests back to back: most reads find data waiting |
| `idle1ms` | keep-alive with 1 ms gaps: nearly every request pauses on the socket |
| `churn` | one request per connection: accept + connect + close dominate |

The number to read is **server CPU per request** (utime+stime of the server process), not
requests per second: the load generator shares the machine, so rps mostly measures it.

| mode | what it is |
|---|---|
| `stock` | `readSome` / `write`: allocates a string per read |
| `zerocopy` | `recvInto` / `sendFrom` on one buffer per connection |
| `ring` | the same handler on io_uring (`ringEnable()`) |

`loadgen` can be used on its own against any server:
`loadgen -addr 127.0.0.1:8080 -conns 64 -secs 5 [-gap 1ms | -churn]`.
