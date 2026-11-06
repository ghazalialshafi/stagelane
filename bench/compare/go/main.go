package main

import (
	"fmt"
	"os"
	"runtime"
	"strconv"
	"sync"
	"time"
)

var sink int64

func report(name string, ops int, t0 time.Time) {
	fmt.Printf("RESULT\tgo\t%s\t%d\t%d\n", name, ops, time.Since(t0).Microseconds())
}

//go:noinline
func leaf(x int) int {
	if x < 0 {
		runtime.Gosched()
	}
	return x + 1
}
func crunch(n int) int {
	r := 0
	for i := 1; i <= n; i++ {
		r += i % 7
	}
	return r
}

func main() {
	only := ""
	if len(os.Args) > 1 {
		only = os.Args[1]
	}
	pn := 20000
	if len(os.Args) > 2 {
		pn, _ = strconv.Atoi(os.Args[2])
	}
	want := func(n string) bool { return only == "" || only == n }
	var t0 time.Time
	if want("call") {
		t0 = time.Now()
		s := 0
		for i := 0; i < 10_000_000; i++ {
			s += leaf(i)
		}
		sink += int64(s)
		report("call_10M", 10_000_000, t0)
	}
	if want("yield") {
		t0 = time.Now()
		var wg sync.WaitGroup
		wg.Add(1)
		go func() {
			for i := 0; i < 2_000_000; i++ {
				runtime.Gosched()
			}
			wg.Done()
		}()
		wg.Wait()
		report("yield_2M", 2_000_000, t0)
	}
	if want("spawn") {
		t0 = time.Now()
		var wg sync.WaitGroup
		wg.Add(200_000)
		for i := 0; i < 200_000; i++ {
			go func(x int) { sink += 0; wg.Done() }(i)
		}
		wg.Wait()
		report("spawn_200k", 200_000, t0)
	}
	if want("fanout") {
		t0 = time.Now()
		var wg sync.WaitGroup
		wg.Add(100_000)
		for i := 0; i < 100_000; i++ {
			go func() {
				runtime.Gosched()
				runtime.Gosched()
				runtime.Gosched()
				wg.Done()
			}()
		}
		wg.Wait()
		report("fanout_100k_x3yield", 400_000, t0)
	}
	if want("pingpong") {
		a := make(chan int, 1)
		b := make(chan int, 1)
		var wg sync.WaitGroup
		wg.Add(2)
		t0 = time.Now()
		go func() {
			for i := 0; i < 200_000; i++ {
				a <- i
				<-b
			}
			wg.Done()
		}()
		go func() {
			for i := 0; i < 200_000; i++ {
				b <- (<-a) + 1
			}
			wg.Done()
		}()
		wg.Wait()
		report("pingpong_200k", 400_000, t0)
	}
	if want("timers") {
		t0 = time.Now()
		var wg sync.WaitGroup
		wg.Add(100_000)
		for i := 0; i < 100_000; i++ {
			go func(ms int) { time.Sleep(time.Duration(ms) * time.Millisecond); wg.Done() }(1 + i%5)
		}
		wg.Wait()
		report("timers_100k", 100_000, t0)
	}
	if want("cpu") {
		t0 = time.Now()
		var wg sync.WaitGroup
		var mu sync.Mutex
		wg.Add(64)
		for i := 0; i < 64; i++ {
			go func() {
				r := crunch(2_000_000)
				mu.Lock()
				sink += int64(r)
				mu.Unlock()
				wg.Done()
			}()
		}
		wg.Wait()
		report("cpu_64x2M", 64, t0)
	}
	if want("pipe") {
		c := make(chan int, 128)
		var wg sync.WaitGroup
		wg.Add(2)
		t0 = time.Now()
		go func() {
			for i := 0; i < pn; i++ {
				c <- i
			}
			wg.Done()
		}()
		go func() {
			t := 0
			for i := 0; i < pn; i++ {
				t += <-c
			}
			sink += int64(t)
			wg.Done()
		}()
		wg.Wait()
		report(fmt.Sprintf("chan_pipe_%d", pn), pn, t0)
	}
	fmt.Fprintln(os.Stderr, "sink", sink)
}
