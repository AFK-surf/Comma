package main

import (
	"encoding/json"
	"net/http"
	"net/http/httptest"
	"os"
	"strings"
	"testing"
)

func TestCommaClientCLICallsDeclarativeMainAPIWithInjectedBearer(t *testing.T) {
	var got map[string]any
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		if r.Header.Get("Authorization") != "Bearer launch-token" {
			http.Error(w, "unauthorized", http.StatusUnauthorized)
			return
		}
		if r.URL.Path != "/v1/invoke" {
			http.NotFound(w, r)
			return
		}
		if err := json.NewDecoder(r.Body).Decode(&got); err != nil {
			http.Error(w, err.Error(), http.StatusBadRequest)
			return
		}
		_ = json.NewEncoder(w).Encode(map[string]any{"ok": true})
	}))
	defer server.Close()
	t.Setenv(commaClientControlURLEnv, server.URL)
	t.Setenv(commaClientControlTokenEnv, "launch-token")

	output := captureCommaCLIStdout(t, func() error {
		return runCommaClientCLI([]string{"call", "global-settings", "update", "--json", `{"showInDock":false}`})
	})
	if !strings.Contains(output, `"ok":true`) {
		t.Fatalf("output = %q", output)
	}
	if got["module"] != "global-settings" || got["api"] != "update" {
		t.Fatalf("request = %#v", got)
	}
	input, _ := got["input"].(map[string]any)
	if input["showInDock"] != false {
		t.Fatalf("input = %#v", input)
	}
}

func captureCommaCLIStdout(t *testing.T, run func() error) string {
	t.Helper()
	reader, writer, err := os.Pipe()
	if err != nil {
		t.Fatal(err)
	}
	previous := os.Stdout
	os.Stdout = writer
	defer func() { os.Stdout = previous }()
	if err := run(); err != nil {
		t.Fatal(err)
	}
	_ = writer.Close()
	buffer := make([]byte, 4096)
	n, err := reader.Read(buffer)
	if err != nil {
		t.Fatal(err)
	}
	_ = reader.Close()
	return string(buffer[:n])
}
