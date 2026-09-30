package main

import (
	"context"
	"fmt"
	"net/http"
	"net/http/httptest"
	"strings"
	"testing"

	"github.com/AFK-surf/comma/systems/ops/comma-release/release"
	"github.com/slack-go/slack"
)

type shutdownSecretRunner struct{}

func (shutdownSecretRunner) Run(_ context.Context, _ []byte, args ...string) ([]byte, error) {
	joined := strings.Join(args, " ")
	if !strings.Contains(joined, "alert-router-slack-staging") || !strings.Contains(joined, "test-project") {
		return nil, fmt.Errorf("wrong credential source")
	}
	return []byte(`{"SLACK_BOT_TOKEN":"test-token"}`), nil
}
func TestShutdownNoticeUsesExistingCredentialAndSelectedChannel(t *testing.T) {
	calls := 0
	issueURL := "https://github.com/org/repo/issues/1"
	server := httptest.NewServer(http.HandlerFunc(func(w http.ResponseWriter, r *http.Request) {
		calls++
		if r.URL.Path != "/chat.postMessage" {
			t.Errorf("unexpected Slack operation: %s", r.URL.Path)
		}
		if err := r.ParseForm(); err != nil {
			t.Fatal(err)
		}
		if r.Form.Get("channel") != "C0BAJ7A71H8" || !strings.Contains(r.Form.Get("text"), issueURL) {
			t.Errorf("wrong notice destination/content: %v", r.Form)
		}
		if r.Header.Get("Authorization") != "Bearer test-token" && r.Form.Get("token") != "test-token" {
			t.Error("existing bot credential was not used")
		}
		w.Header().Set("Content-Type", "application/json")
		fmt.Fprint(w, `{"ok":true,"channel":"C0BAJ7A71H8","ts":"1"}`)
	}))
	defer server.Close()
	notify := shutdownSlackNotifier(release.EnvironmentSpec{Environment: "staging", Project: "test-project"}, shutdownSecretRunner{}, slack.OptionAPIURL(server.URL+"/"))
	if err := notify(context.Background(), issueURL); err != nil {
		t.Fatal(err)
	}
	if calls != 1 {
		t.Fatalf("sent %d Slack messages", calls)
	}
}
