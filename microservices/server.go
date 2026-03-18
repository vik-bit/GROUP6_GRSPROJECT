package main

import (
	"fmt"
	"io"
	"net/http"
	"os"
)

var next = os.Getenv("NEXT_SERVICE")

func handler(w http.ResponseWriter, r *http.Request) {

	if next == "" {
		fmt.Fprintf(w, "service-c\n")
		return
	}

	resp, err := http.Get(next)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}
	defer resp.Body.Close()

	body, err := io.ReadAll(resp.Body)
	if err != nil {
		http.Error(w, err.Error(), 500)
		return
	}

	fmt.Fprintf(w, "-> %s", string(body))
}

func main() {
	http.HandleFunc("/", handler)

	fmt.Println("Listening on :8080")
	http.ListenAndServe(":8080", nil)
}