package main

import (
	"errors"
	"fmt"
	"os"
	"os/exec"
	"os/signal"
	"syscall"
	"time"
)

const gracefulShutdownTimeout = 10 * time.Second

type child struct {
	name string
	cmd  *exec.Cmd
}

type childExit struct {
	child child
	err   error
}

// comma-meeting-runtime is the explicit owner of the two processes in the
// meeting image. If either process exits, the runtime is unhealthy and the
// sibling is terminated; Agent VMM can then recreate the fenced generation.
func main() {
	children := []child{
		{name: "xvfb", cmd: exec.Command("Xvfb", ":99", "-screen", "0", "1280x720x24", "-nolisten", "tcp")},
		{name: "meetnative", cmd: exec.Command("meet-native", "serve")},
		{name: "runtime-agent", cmd: exec.Command("salix-runtime-agent", "--runtime-agent", "--meet-url=http://127.0.0.1:8081")},
	}
	if err := supervise(children); err != nil {
		fmt.Fprintln(os.Stderr, err)
		os.Exit(1)
	}
}

func supervise(children []child) error {
	if len(children) == 0 {
		return errors.New("meeting runtime requires child processes")
	}
	exits := make(chan childExit, len(children))
	started := make([]child, 0, len(children))
	for _, item := range children {
		item.cmd.Stdout = os.Stdout
		item.cmd.Stderr = os.Stderr
		if err := item.cmd.Start(); err != nil {
			terminate(started)
			return fmt.Errorf("start %s: %w", item.name, err)
		}
		started = append(started, item)
		go func(item child) { exits <- childExit{child: item, err: item.cmd.Wait()} }(item)
	}

	signals := make(chan os.Signal, 1)
	signal.Notify(signals, os.Interrupt, syscall.SIGTERM)
	defer signal.Stop(signals)

	select {
	case sig := <-signals:
		terminate(started)
		waitForChildren(exits, len(started))
		_ = sig
		return nil
	case result := <-exits:
		terminateExcept(started, result.child.cmd)
		waitForChildren(exits, len(started)-1)
		if result.err == nil {
			return fmt.Errorf("%s exited unexpectedly", result.child.name)
		}
		return fmt.Errorf("%s exited: %w", result.child.name, result.err)
	}
}

func terminate(children []child) {
	terminateExcept(children, nil)
}

func terminateExcept(children []child, except *exec.Cmd) {
	for _, item := range children {
		if item.cmd == except || item.cmd.Process == nil {
			continue
		}
		_ = item.cmd.Process.Signal(syscall.SIGTERM)
	}
}

func waitForChildren(exits <-chan childExit, count int) {
	timer := time.NewTimer(gracefulShutdownTimeout)
	defer timer.Stop()
	for count > 0 {
		select {
		case <-exits:
			count--
		case <-timer.C:
			return
		}
	}
}
