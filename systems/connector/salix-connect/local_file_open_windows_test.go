//go:build windows

package main

import (
	"io"
	"os"
	"path/filepath"
	"testing"
)

func TestWindowsPinnedRootOpensChildrenFromOriginalDirectoryAfterReplacement(t *testing.T) {
	base := t.TempDir()
	root := filepath.Join(base, "local-file-index")
	if err := os.Mkdir(root, 0o700); err != nil {
		t.Fatal(err)
	}
	trusted := []byte("trusted")
	ref := writeLocalFileFixture(t, root, trusted, "registered")

	rootedRoot, err := openWindowsDirectoryNoFollow(root)
	if err != nil {
		t.Fatal(err)
	}
	moved := filepath.Join(base, "original-local-file-index")
	if err := os.Rename(root, moved); err != nil {
		_ = rootedRoot.Close()
		t.Fatal(err)
	}
	if err := os.Mkdir(root, 0o700); err != nil {
		_ = rootedRoot.Close()
		t.Fatal(err)
	}
	writeLocalFileFixtureWithRef(t, root, ref, []byte("attacker"), "registered")

	index, err := openPinnedLocalFileIndexFromRoot(rootedRoot)
	if err != nil {
		t.Fatal(err)
	}
	defer index.close()
	record, err := readLocalFileIndexRecordFrom(index, ref)
	if err != nil {
		t.Fatal(err)
	}
	if record.Size != int64(len(trusted)) {
		t.Fatalf("pinned entries root escaped to replacement directory: size=%d", record.Size)
	}
	file, err := index.openObject(record.ObjectID)
	if err != nil {
		t.Fatal(err)
	}
	defer file.Close()
	contents, err := io.ReadAll(file)
	if err != nil {
		t.Fatal(err)
	}
	if string(contents) != string(trusted) {
		t.Fatalf("pinned root escaped to ordinary replacement directory: %q", contents)
	}
}
