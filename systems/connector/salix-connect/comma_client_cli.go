package main

import (
	"bytes"
	"context"
	"encoding/json"
	"errors"
	"fmt"
	"io"
	"net/http"
	"net/url"
	"os"
	"strings"
	"time"
)

const (
	commaClientControlURLEnv   = "COMMA_CLIENT_CONTROL_URL"
	commaClientControlTokenEnv = "COMMA_CLIENT_CONTROL_TOKEN"
	maxCommaClientResponse     = 1024 * 1024
)

func runCommaClientCLI(args []string) error {
	if len(args) == 0 || args[0] == "help" || args[0] == "-h" || args[0] == "--help" {
		printCommaClientUsage()
		return nil
	}
	endpoint := strings.TrimRight(strings.TrimSpace(os.Getenv(commaClientControlURLEnv)), "/")
	token := strings.TrimSpace(os.Getenv(commaClientControlTokenEnv))
	if endpoint == "" || token == "" {
		return errors.New("Comma client control is unavailable in this environment")
	}

	switch args[0] {
	case "modules":
		if len(args) != 1 {
			return errors.New("usage: comma modules")
		}
		return commaClientRequest(http.MethodGet, endpoint+"/v1/modules", token, nil)
	case "describe":
		if len(args) != 2 || strings.TrimSpace(args[1]) == "" {
			return errors.New("usage: comma describe <module>")
		}
		return commaClientRequest(http.MethodGet, endpoint+"/v1/modules/"+url.PathEscape(args[1]), token, nil)
	case "call":
		if len(args) < 3 {
			return errors.New("usage: comma call <module> <api> [--json '<object>']")
		}
		input := json.RawMessage(`{}`)
		for index := 3; index < len(args); index++ {
			if args[index] != "--json" || index+1 >= len(args) {
				return errors.New("usage: comma call <module> <api> [--json '<object>']")
			}
			input = json.RawMessage(args[index+1])
			index++
		}
		var object map[string]any
		if err := json.Unmarshal(input, &object); err != nil || object == nil {
			return errors.New("--json must be a JSON object")
		}
		body, _ := json.Marshal(map[string]any{
			"module": args[1],
			"api":    args[2],
			"input":  object,
		})
		return commaClientRequest(http.MethodPost, endpoint+"/v1/invoke", token, bytes.NewReader(body))
	default:
		return fmt.Errorf("unknown comma command %q", args[0])
	}
}

func printCommaClientUsage() {
	fmt.Fprintln(os.Stdout, "usage: comma modules | comma describe <module> | comma call <module> <api> [--json '<object>']")
}

func commaClientRequest(method, endpoint, token string, body io.Reader) error {
	ctx, cancel := context.WithTimeout(context.Background(), 30*time.Second)
	defer cancel()
	raw, err := commaClientResponse(ctx, method, endpoint, token, body)
	if err != nil {
		return err
	}
	if len(raw) > 0 {
		_, _ = os.Stdout.Write(raw)
		if raw[len(raw)-1] != '\n' {
			_, _ = os.Stdout.Write([]byte("\n"))
		}
	}
	return nil
}

func commaClientResponse(ctx context.Context, method, endpoint, token string, body io.Reader) ([]byte, error) {
	req, err := http.NewRequestWithContext(ctx, method, endpoint, body)
	if err != nil {
		return nil, err
	}
	req.Header.Set("Authorization", "Bearer "+token)
	if body != nil {
		req.Header.Set("Content-Type", "application/json")
	}
	client := &http.Client{CheckRedirect: func(*http.Request, []*http.Request) error {
		return http.ErrUseLastResponse
	}}
	response, err := client.Do(req)
	if err != nil {
		return nil, err
	}
	defer response.Body.Close()
	raw, err := io.ReadAll(io.LimitReader(response.Body, maxCommaClientResponse+1))
	if err != nil {
		return nil, err
	}
	if len(raw) > maxCommaClientResponse {
		return nil, errors.New("Comma client response exceeds limit")
	}
	if response.StatusCode >= 400 {
		return nil, fmt.Errorf("Comma client API returned HTTP %d", response.StatusCode)
	}
	return raw, nil
}
