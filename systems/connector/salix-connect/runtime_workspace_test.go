package main

import (
	"errors"
	"os"
	"syscall"
	"testing"
)

func TestWorkspaceReadinessMessageClassifiesSafeOwnerFailures(t *testing.T) {
	t.Setenv("HOME", "/safe-home")
	for _, tc := range []struct {
		err  error
		want string
	}{
		{os.ErrPermission, "The external runtime workspace is not writable by the Connector."},
		{syscall.ENOSPC, "The external runtime workspace cannot be prepared because the device has no free disk space."},
		{errors.New("mkdir /private/home: provider token=secret"), "The external runtime workspace could not be prepared."},
	} {
		if got := runtimeWorkspaceReadinessMessage(tc.err); got != tc.want {
			t.Fatalf("workspace message = %q, want %q", got, tc.want)
		}
	}
}
