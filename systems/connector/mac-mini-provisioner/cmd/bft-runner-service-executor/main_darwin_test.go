package main

import (
	"context"
	"strings"
	"testing"
)

func TestRunnerDefinitionUsesOnlyConfiguredIdentity(t *testing.T) {
	t.Parallel()
	config := ownerConfig{User: "service<&", Group: "staff", Home: "/Users/service"}
	job := resolveRunnerJob(config)
	definition := string(renderPlist(config, job))
	for _, expected := range []string{runnerLabel, "/Users/service/.bridge-for-teams/bin/bft-runner", "<key>UserName</key><string>service&lt;&amp;</string>", "<key>GroupName</key><string>staff</string>", "/Library/Logs/BridgeForTeams/runner.out.log", "<key>NumberOfFiles</key><integer>65536</integer>", "<key>NumberOfFiles</key><integer>524288</integer>"} {
		if !strings.Contains(definition, expected) {
			t.Fatalf("missing %q", expected)
		}
	}
	for _, args := range [][]string{{"--job", "runner"}, {"--path", "/tmp/forged"}} {
		if err := parseAction("install", args); err == nil {
			t.Fatalf("accepted %v", args)
		}
	}
}

func TestRunnerStartDoesNotRestartLiveProcess(t *testing.T) {
	t.Parallel()
	owner := executor{system: runnerSystem{Launchctl: func(_ context.Context, args ...string) error {
		if args[0] != "print" {
			t.Fatalf("restarted live runner: %v", args)
		}
		return nil
	}, ServicePID: func(context.Context, string) (int, error) { return 42, nil }, ProcessRunning: func(int) bool { return true }}}
	if err := owner.startJob(fixedJob{label: runnerLabel}); err != nil {
		t.Fatal(err)
	}
}
