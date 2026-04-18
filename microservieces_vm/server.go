package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
	"time"
)

var next = os.Getenv("NEXT_SERVICE")

var client = &http.Client{
	Timeout: 10 * time.Second,
}

func handler(w http.ResponseWriter, r *http.Request) {

	if next == "" {
		fmt.Fprintf(w, "service-c\n")
		return
	}

	ctx, cancel := context.WithTimeout(r.Context(), 5*time.Second)
	defer cancel()

	resp, err := http.NewRequestWithContext(ctx, "GET", next, nil)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to create request: %v", err), 500)
		return
	}
	resp, err := client.Do(req)
	if err != nil {
		http.Error(w, fmt.Sprintf("Downstream error (Service B): %v", err), 504)
		return
	}

	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, fmt.Sprintf("Failed to read response: %v", err), 500)
		return
	}

	fmt.Fprintf(w, "-> %s", string(body))
}

func main() {
	http.HandleFunc("/", handler)

	server := &http.Server{
		Addr:         ":8080",
		ReadTimeout:  5 * time.Second,
		WriteTimeout: 10 * time.Second,
	}

	fmt.Println("Listening on :8080 (with timeouts)")
	if err := server.ListenAndServe(); err != nil {
		fmt.Printf("Server failed: %s\n", err)
	}
}