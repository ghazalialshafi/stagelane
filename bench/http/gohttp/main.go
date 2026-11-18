package main

import (
	"fmt"
	"net/http"
	"os"
)

func main() {
	port := "8082"
	if len(os.Args) > 1 {
		port = os.Args[1]
	}
	http.HandleFunc("/", func(w http.ResponseWriter, r *http.Request) {
		w.Header().Set("Content-Type", "text/plain")
		fmt.Fprint(w, "Hello, World!")
	})
	fmt.Println("listening on", port)
	http.ListenAndServe(":"+port, nil)
}
