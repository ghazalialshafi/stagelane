// Load generator: keep-alive connections with an optional idle gap between requests,
// or connection churn (one request per connection).
//   loadgen -addr 127.0.0.1:8081 -conns 64 -secs 4 -gap 1ms        (idle keep-alive)
//   loadgen -addr 127.0.0.1:8081 -conns 64 -secs 4 -churn           (connection churn)
package main

import (
	"bytes"
	"flag"
	"fmt"
	"io"
	"net"
	"sync"
	"sync/atomic"
	"time"
)

var req = []byte("GET / HTTP/1.1\r\nHost: bench\r\n\r\n")

// reads one response: headers then Content-Length body bytes
func readResp(c net.Conn, buf []byte) error {
	got := 0
	for {
		n, err := c.Read(buf[got:])
		if n > 0 {
			got += n
		}
		if i := bytes.Index(buf[:got], []byte("\r\n\r\n")); i >= 0 {
			if bytes.Contains(buf[:got], []byte("Content-Length: 13")) && got >= i+4+13 {
				return nil
			}
		}
		if err != nil {
			return err
		}
	}
}

func main() {
	addr := flag.String("addr", "127.0.0.1:8081", "")
	conns := flag.Int("conns", 64, "")
	secs := flag.Int("secs", 4, "")
	gap := flag.Duration("gap", 0, "idle time between requests on one connection")
	churn := flag.Bool("churn", false, "new connection per request")
	flag.Parse()
	var total, errs int64
	stop := time.Now().Add(time.Duration(*secs) * time.Second)
	var wg sync.WaitGroup
	for i := 0; i < *conns; i++ {
		wg.Add(1)
		go func() {
			defer wg.Done()
			buf := make([]byte, 4096)
			var c net.Conn
			for time.Now().Before(stop) {
				if c == nil {
					var err error
					c, err = net.Dial("tcp", *addr)
					if err != nil {
						atomic.AddInt64(&errs, 1)
						time.Sleep(time.Millisecond)
						continue
					}
				}
				if _, err := c.Write(req); err != nil {
					atomic.AddInt64(&errs, 1)
					c.Close()
					c = nil
					continue
				}
				if err := readResp(c, buf); err != nil && err != io.EOF {
					atomic.AddInt64(&errs, 1)
					c.Close()
					c = nil
					continue
				}
				atomic.AddInt64(&total, 1)
				if *churn {
					c.Close()
					c = nil
				} else if *gap > 0 {
					time.Sleep(*gap)
				}
			}
			if c != nil {
				c.Close()
			}
		}()
	}
	wg.Wait()
	fmt.Printf("requests=%d errors=%d rps=%.0f\n", total, errs, float64(total)/float64(*secs))
}
