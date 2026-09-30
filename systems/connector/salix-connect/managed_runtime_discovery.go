package main

import (
	"os"
	"path/filepath"
	"sort"
)

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
		path := filepath.Join(root, name, "bin", provider)
		if executable(path) {
			paths = append(paths, path)
		}
	}
	return paths
}
