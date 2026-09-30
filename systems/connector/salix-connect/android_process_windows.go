//go:build windows

package main

import (
	"context"
	"errors"
	"os"
)

type androidOwnedProcess struct {
	process *os.Process
	profile string
	done    <-chan struct{}
}

func (o *androidOwnedProcess) alive() bool {
	if o.done == nil {
		return false
	}
	select {
	case <-o.done:
		return false
	default:
		return true
	}
}

func (o *androidOwnedProcess) release() {
	_ = o.process.Release()
}

func (p *androidProvider) stopProcess(context.Context) error {
	return errors.New("Android profiles require Linux x86_64")
}

func (p *androidProvider) discoverProcess(context.Context) (*androidOwnedProcess, error) {
	return nil, errors.New("Android profiles require Linux x86_64")
}

func (p *androidProvider) matchesAndroidProcess([]byte, androidProfileSpec) bool {
	return false
}
