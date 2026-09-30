package main

import (
	"os"
	"path/filepath"
	"strings"
)

// installedDependencyDir is used only by the scoped workspace sweep archive.
// Full-disk Group archives retain installation trees, including local edits.
func installedDependencyDir(path, archivePath string, entry os.DirEntry) bool {
	if !entry.IsDir() {
		return false
	}
	switch entry.Name() {
	case "node_modules":
		// The owner has designated Node installation directories rebuildable,
		// including repositories that do not keep a lockfile.
		return true
	case "site-packages":
		parent := filepath.Base(filepath.Dir(path))
		if !strings.HasPrefix(parent, "python3.") ||
			!strings.HasPrefix(cleanArchivePath(archivePath), ".salix/sprite-home/.local/lib/") {
			return false
		}
		entries, err := os.ReadDir(path)
		if err != nil {
			return false
		}
		for _, child := range entries {
			if child.IsDir() && strings.HasSuffix(child.Name(), ".dist-info") {
				return true
			}
		}
	}
	// A venv may have any user-chosen name, such as document-math.
	return exists(filepath.Join(path, "pyvenv.cfg"))
}

func exists(path string) bool {
	_, err := os.Lstat(path)
	return err == nil
}

func cleanArchivePath(path string) string {
	return strings.TrimPrefix(filepath.ToSlash(filepath.Clean(path)), "./")
}
