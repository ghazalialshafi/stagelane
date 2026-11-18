# Results (1 CPUs, multi workers=4, median of 5)

ns/op (lower is better); cpu and timers are total ms; HANG = no result within the timeout


## single

| benchmark | stagelane | nimony .passive | go | best |
|---|---|---|---|---|
| call_10M | 10.1 | 14.5 | 1.5 | go (go: plain call, not comparable) |
| yield_2M | 10.5 | 96.7 | 112.1 | stagelane |
| spawn_200k | 14.6 | 63.0 | 926.5 | stagelane |
| fanout_100k_x3yield | 23.8 | 52.0 | 617.6 | stagelane |
| pingpong_200k | 48.8 | 495.3 | 159.2 | stagelane |
| timers_100k | 33 ms | 49 ms | 241 ms | stagelane |
| cpu_64x2M | 105 ms | 116 ms | 111 ms | stagelane |
| chan_pipe_20000 | 19.1 | 186.2 | 47.9 | stagelane |
| chan_pipe_500000 | 23.5 | HANG | 46.4 | stagelane |

## multi

| benchmark | stagelane | nimony .passive | go | best |
|---|---|---|---|---|
| call_10M | 10.3 | 18.5 | 1.5 | go (go: plain call, not comparable) |
| yield_2M | 10.6 | 91.9 | 96.9 | stagelane |
| spawn_200k | 190.5 | 64.8 | 579.8 | nimony |
| spawn_detached_200k (nimony/go: their fire-and-forget spawn) | 67.1 | 70.3 | 621.2 | stagelane |
| fanout_100k_x3yield | 31.4 | 59.2 | 301.9 | stagelane |
| pingpong_200k | 46.3 | 443.6 | 195.6 | stagelane |
| timers_100k | 33 ms | 45 ms | 213 ms | stagelane |
| cpu_64x2M | 112 ms | 121 ms | 115 ms | stagelane |
| chan_pipe_20000 | 23.8 | HANG | 70.2 | stagelane |
| chan_pipe_500000 | 32.3 | HANG | 65.1 | stagelane |