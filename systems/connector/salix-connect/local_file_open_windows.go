//go:build windows

package main

import (
	"os"
	"strings"
)

func openPinnedLocalFileIndex(root string) (*localFileIndexHandle, error) {
	rootedRoot, err := openWindowsDirectoryNoFollow(root)
	if err != nil {
		return nil, err
	}
	return openPinnedLocalFileIndexFromRoot(rootedRoot)
}

// openPinnedLocalFileIndexFromRoot takes ownership of rootedRoot. Child roots
// must be opened relative to this already-pinned handle: reopening them from
// rootedRoot.Name() would allow a rename-and-replace of the managed root to
// redirect the index between the root and child opens.
func openPinnedLocalFileIndexFromRoot(rootedRoot *os.Root) (*localFileIndexHandle, error) {
	index := &localFileIndexHandle{rootedRoot: rootedRoot}
	fail := func(err error) (*localFileIndexHandle, error) {
		index.close()
		return nil, err
	}
	if rootedRoot == nil {
		return fail(errLocalFileUnavailable)
	}
	var err error
	index.rootedEntries, err = openWindowsDirectoryAt(rootedRoot, "entries")
	if err != nil {
		return fail(err)
	}
	index.rootedObjects, err = openWindowsDirectoryAt(rootedRoot, "objects")
	if err != nil {
		return fail(err)
	}
	return index, nil
}

func (index *localFileIndexHandle) openEntryFile(name string) (*os.File, error) {
	return openLocalFileAt(index.rootedEntries, name)
}

func (index *localFileIndexHandle) openObjectFile(name string) (*os.File, error) {
	return openLocalFileAt(index.rootedObjects, name)
}

func openLocalFileAt(directory *os.Root, name string) (*os.File, error) {
	if directory == nil || !safeLocalFileChildName(name) {
		return nil, errLocalFileUnavailable
	}
	before, err := directory.Lstat(name)
	if err != nil || before.Mode()&os.ModeSymlink != 0 {
		return nil, errLocalFileUnavailable
	}
	file, err := directory.Open(name)
	if err != nil {
		return nil, err
	}
	after, statErr := file.Stat()
	if statErr != nil || !os.SameFile(before, after) {
		_ = file.Close()
		return nil, errLocalFileUnavailable
	}
	return file, nil
}

func openWindowsDirectoryNoFollow(path string) (*os.Root, error) {
	before, err := os.Lstat(path)
	if err != nil || !before.IsDir() || before.Mode()&os.ModeSymlink != 0 || !localFileModePrivate(before.Mode()) {
		return nil, errLocalFileUnavailable
	}
	directory, err := os.OpenRoot(path)
	if err != nil {
		return nil, err
	}
	after, statErr := directory.Stat(".")
	if statErr != nil || !os.SameFile(before, after) {
		_ = directory.Close()
		return nil, errLocalFileUnavailable
	}
	return directory, nil
}

func openWindowsDirectoryAt(parent *os.Root, name string) (*os.Root, error) {
	if parent == nil || !safeLocalFileChildName(name) {
		return nil, errLocalFileUnavailable
	}
	before, err := parent.Lstat(name)
	if err != nil || !before.IsDir() || before.Mode()&os.ModeSymlink != 0 || !localFileModePrivate(before.Mode()) {
		return nil, errLocalFileUnavailable
	}
	directory, err := parent.OpenRoot(name)
	if err != nil {
		return nil, err
	}
	after, statErr := directory.Stat(".")
	if statErr != nil || !os.SameFile(before, after) {
		_ = directory.Close()
		return nil, errLocalFileUnavailable
	}
	return directory, nil
}

func safeLocalFileChildName(name string) bool {
	return name != "" && name != "." && name != ".." &&
		!strings.ContainsAny(name, `/\\`) && !strings.ContainsRune(name, 0)
}
