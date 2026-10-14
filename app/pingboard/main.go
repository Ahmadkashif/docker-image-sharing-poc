// pingboard: a tiny HTTP service used to prove the img kit end to end (build -> sign -> ship -> run).
// It reports which build and which CPU architecture it is running on, so a deploy can be checked from outside.
package main

import (
	"encoding/json"
	"flag"
	"fmt"
	"log"
	"net/http"
	"os"
	"runtime"
	"sync/atomic"
	"time"
)

var (
	version = "dev"  // -ldflags "-X main.version=..."
	commit  = "none" // -ldflags "-X main.commit=..."
	started = time.Now()
	hits    atomic.Int64
)

type status struct {
	App     string `json:"app"`
	Version string `json:"version"`
	Commit  string `json:"commit"`
	GOOS    string `json:"goos"`
	GOARCH  string `json:"goarch"`
	Go      string `json:"go"`
	Host    string `json:"host"`
	Uptime  string `json:"uptime"`
	Hits    int64  `json:"hits"`
}

func main() {
	addr := flag.String("addr", ":8080", "listen address")
	health := flag.Bool("healthcheck", false, "probe http://127.0.0.1:8080/health and exit 0/1 (for HEALTHCHECK in images without a shell)")
	flag.Parse()
	if *health {
		c := http.Client{Timeout: 2 * time.Second}
		r, err := c.Get("http://127.0.0.1:8080/health")
		if err != nil || r.StatusCode != http.StatusOK {
			os.Exit(1)
		}
		os.Exit(0)
	}
	mux := http.NewServeMux()
	mux.HandleFunc("/health", func(w http.ResponseWriter, _ *http.Request) { fmt.Fprintln(w, "ok") })
	mux.HandleFunc("/", func(w http.ResponseWriter, _ *http.Request) {
		host, _ := os.Hostname()
		w.Header().Set("Content-Type", "application/json")
		_ = json.NewEncoder(w).Encode(status{"pingboard", version, commit, runtime.GOOS, runtime.GOARCH, runtime.Version(),
			host, time.Since(started).Round(time.Second).String(), hits.Add(1)})
	})
	log.Printf("pingboard %s (%s) %s/%s listening on %s", version, commit, runtime.GOOS, runtime.GOARCH, *addr)
	srv := &http.Server{Addr: *addr, Handler: mux, ReadHeaderTimeout: 5 * time.Second}
	log.Fatal(srv.ListenAndServe())
}
