//go:build linux

package main

import (
	"errors"
	"fmt"
	"os"
	"strconv"
	"strings"

	"golang.org/x/sys/unix"
)

func checkAndroidHostCapacity(runtimeRoot string) error {
	data, err := os.ReadFile("/proc/meminfo")
	if err != nil {
		return fmt.Errorf("read host memory: %w", err)
	}
	var memoryKiB uint64
	for _, line := range strings.Split(string(data), "\n") {
		fields := strings.Fields(line)
		if len(fields) >= 2 && fields[0] == "MemTotal:" {
			memoryKiB, _ = strconv.ParseUint(fields[1], 10, 64)
			break
		}
	}
	if memoryKiB < 7*1024*1024 {
		return errors.New("Android host requires at least 7 GiB RAM")
	}
	var stat unix.Statfs_t
	if err := unix.Statfs(runtimeRoot, &stat); err != nil {
		return fmt.Errorf("read Android runtime disk capacity: %w", err)
	}
	free := uint64(stat.Bavail) * uint64(stat.Bsize)
	if free < 8<<30 {
		return errors.New("Android runtime requires at least 8 GiB free disk")
	}
	return nil
}
