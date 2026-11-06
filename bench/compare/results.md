# Results (1 CPUs, multi workers=4, median of 5)

ns/op (lower is better); cpu and timers are total ms; HANG = no result within the timeout


## single

| benchmark | stagelane | nimony .passive | go | best |
|---|---|---|---|---|
| call_10M | 9.9 | 16.8 | 1.5 | go (go: plain call, not comparable) |
| yield_2M | 11.9 | 90.1 | 108.3 | stagelane |
| spawn_200k | 16.8 | 69.0 | 701.4 | stagelane |
| fanout_100k_x3yield | 21.0 | 47.5 | 471.0 | stagelane |
| pingpong_200k | 51.7 | 460.0 | 193.5 | stagelane |
| timers_100k | 27 ms | 43 ms | 191 ms | stagelane |
| cpu_64x2M | 106 ms | 110 ms | 91 ms | go |
| chan_pipe_20000 | 21.9 | HANG | 67.8 | stagelane |
| chan_pipe_500000 | 39.0 | HANG | 47.9 | stagelane |

## multi

| benchmark | stagelane | nimony .passive | go | best |
|---|---|---|---|---|
| call_10M | 9.7 | 16.9 | 1.5 | go (go: plain call, not comparable) |
| yield_2M | 11.8 | 83.7 | 79.9 | stagelane |
| spawn_200k | 239.3 | 69.2 | 469.2 | nimony |
| spawn_detached_200k (nimony/go: their fire-and-forget spawn) | 84.0 | 69.8 | 495.1 | nimony |
| fanout_100k_x3yield | 21.0 | 48.6 | 231.7 | stagelane |
| pingpong_200k | 52.9 | 480.7 | 179.3 | stagelane |
| timers_100k | 28 ms | 45 ms | 169 ms | stagelane |
| cpu_64x2M | 106 ms | 112 ms | 94 ms | go |
| chan_pipe_20000 | 21.6 | 173.3 | 70.4 | stagelane |
| chan_pipe_500000 | 35.0 | HANG | 108.2 | stagelane |