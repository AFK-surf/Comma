package session

import "testing"

func TestURLs(t *testing.T) {
	ws, err := SessionURL("https://salix.example.com/base/", "grp_1")
	if err != nil || ws != "wss://salix.example.com/base/v1/agent-groups/grp_1/voice/sessions" {
		t.Fatalf("SessionURL = %q, %v", ws, err)
	}
	ws, err = SessionURL("http://127.0.0.1:4000", "grp_1")
	if err != nil || ws != "ws://127.0.0.1:4000/v1/agent-groups/grp_1/voice/sessions" {
		t.Fatalf("SessionURL = %q, %v", ws, err)
	}
	ready, err := ReadinessURL("wss://salix.example.com", "grp_1")
	if err != nil || ready != "https://salix.example.com/v1/agent-groups/grp_1/voice" {
		t.Fatalf("ReadinessURL = %q, %v", ready, err)
	}
	// A key must never travel in the URL, so credentials and queries are refused.
	for _, bad := range []string{"https://salix.example.com?key=x", "https://u:p@salix.example.com", "ftp://x", "salix.example.com"} {
		if _, err := SessionURL(bad, "grp_1"); err == nil {
			t.Errorf("SessionURL accepted %q", bad)
		}
	}
	if _, err := SessionURL("https://salix.example.com", "../x"); err == nil {
		t.Error("SessionURL accepted a group with a slash")
	}
}
