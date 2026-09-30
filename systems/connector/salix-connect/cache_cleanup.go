package main

import (
	"errors"
	"fmt"
	"os"
	"path/filepath"
	"sort"
	"strings"
)

// cleanupGeneratedHomeCaches is an operator command. It only removes known
// generated caches from the VM's archived home and never follows cache links.
func cleanupGeneratedHomeCaches(home string) error {
	info, err := os.Lstat(home)
	if err != nil {
		return err
	}
	if !info.IsDir() || info.Mode()&os.ModeSymlink != 0 {
		return errors.New("VM home must be a directory")
	}

	paths := make([]string, 0, len(archiveHomeCacheDirs)+1)
	for path := range archiveHomeCacheDirs {
		paths = append(paths, path)
	}
	paths = append(paths, ".hex/cache.ets")
	sort.Strings(paths)
	for _, relative := range paths {
		if err := removeGeneratedCache(home, relative); err != nil {
			return err
		}
	}
	return nil
}

func removeGeneratedCache(home, relative string) error {
	if relative == "." || filepath.IsAbs(relative) ||
		strings.HasPrefix(relative, "..") {
		return fmt.Errorf("invalid generated cache path: %s", relative)
	}
	parts := strings.Split(filepath.Clean(relative), string(os.PathSeparator))
	current := home
	for _, part := range parts {
		current = filepath.Join(current, part)
		info, err := os.Lstat(current)
		if errors.Is(err, os.ErrNotExist) {
			return nil
		}
		if err != nil {
			return err
		}
		if info.Mode()&os.ModeSymlink != 0 {
			return fmt.Errorf("generated cache path crosses symlink: %s", current)
		}
	}
	return os.RemoveAll(current)
}
