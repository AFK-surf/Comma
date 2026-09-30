//go:build !cgo || nodevice

package main

import (
	"context"
	"fmt"

	"github.com/AFK-surf/comma/systems/voice/comma-voice/internal/session"
)

const noDeviceMessage = "comma-voice: this build has no audio device support (built with -tags nodevice or without cgo); use call --input and --output"

func runDevices(args []string, std stdio) int {
	fs := newFlagSet("devices", std)
	if code, ok := parseFlags(fs, args); !ok {
		return code
	}
	fmt.Fprintln(std.err, noDeviceMessage)
	return exitUsage
}

func runDeviceCall(_ context.Context, _ callFlags, _ session.Options, std stdio) int {
	fmt.Fprintln(std.err, noDeviceMessage)
	return exitUsage
}
