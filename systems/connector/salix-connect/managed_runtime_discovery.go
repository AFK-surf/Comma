package main

import (
	"os"
	"path/filepath"
	"regexp"
	"sort"
)

var managedRuntimeInstallationID = regexp.MustCompile(`^[a-zA-Z0-9][a-zA-Z0-9_-]{0,63}$`)

// Cloud VM installation owns at most sixteen targets. Read one bounded directory
// page; never walk a workspace or use a recursive executable search.
func managedRuntimeCommands(provider string) []string {
	root := os.Getenv("SALIX_MANAGED_RUNTIME_ROOT")
	if root == "" || (provider != "codex" && provider != "claude") {
		return nil
	}
	dir, err := os.Open(root)
	if err != nil {
		return nil
	}
	defer dir.Close()
	names, _ := dir.Readdirnames(17)
	if len(names) > 16 {
		return nil
	}
	sort.Strings(names)
	var paths []string
	for _, name := range names {
		if !managedRuntimeInstallationID.MatchString(name) {
			continue
		}
		path := filepath.Join(root, name, "bin", provider)
		// The published entry owns identity even when its package is missing.
		// Empty directories and unpublished temporary entries grant no target.
		info, err := os.Lstat(path)
		if err == nil && (info.Mode()&os.ModeSymlink != 0 || info.Mode().IsRegular() && info.Mode()&0o111 != 0) {
			paths = append(paths, path)
		}
	}
	return paths
}
