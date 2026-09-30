//go:build darwin || linux

package main

import (
	"os"
	"path/filepath"
	"strings"

	"golang.org/x/sys/unix"
)

func openPinnedLocalFileIndex(root string) (*localFileIndexHandle, error) {
	rootFile, err := openLocalDirectoryPath(root)
	if err != nil {
		return nil, err
	}
	index := &localFileIndexHandle{root: rootFile}
	fail := func(err error) (*localFileIndexHandle, error) {
		index.close()
		return nil, err
	}
	if err := validateLocalFileDirectory(rootFile); err != nil {
		return fail(err)
	}
	index.entries, err = openLocalDirectoryAt(rootFile, "entries")
	if err != nil {
		return fail(err)
	}
	if err := validateLocalFileDirectory(index.entries); err != nil {
		return fail(err)
	}
	index.objects, err = openLocalDirectoryAt(rootFile, "objects")
	if err != nil {
		return fail(err)
	}
	if err := validateLocalFileDirectory(index.objects); err != nil {
		return fail(err)
	}
	return index, nil
}

func (index *localFileIndexHandle) openEntryFile(name string) (*os.File, error) {
	return openLocalFileAt(index.entries, name)
}

func (index *localFileIndexHandle) openObjectFile(name string) (*os.File, error) {
	return openLocalFileAt(index.objects, name)
}

func openLocalFileAt(directory *os.File, name string) (*os.File, error) {
	if directory == nil || !safeLocalFileChildName(name) {
		return nil, errLocalFileUnavailable
	}
	fd, err := unix.Openat(
		int(directory.Fd()),
		name,
		unix.O_RDONLY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), filepath.Join(directory.Name(), name))
	if file == nil {
		_ = unix.Close(fd)
		return nil, errLocalFileUnavailable
	}
	return file, nil
}

func openLocalDirectoryPath(path string) (*os.File, error) {
	absolute, err := filepath.Abs(path)
	if err != nil || !filepath.IsAbs(absolute) {
		return nil, errLocalFileUnavailable
	}
	before, err := os.Lstat(absolute)
	if err != nil || !before.IsDir() || before.Mode()&os.ModeSymlink != 0 {
		return nil, errLocalFileUnavailable
	}
	// Resolve platform-owned ancestor aliases (for example macOS /var) once,
	// then walk the canonical path with O_NOFOLLOW. The final descriptor must
	// still name the exact directory observed before resolution.
	absolute, err = filepath.EvalSymlinks(filepath.Clean(absolute))
	if err != nil || !filepath.IsAbs(absolute) {
		return nil, errLocalFileUnavailable
	}
	fd, err := unix.Open(
		string(filepath.Separator),
		unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	currentName := string(filepath.Separator)
	for _, component := range strings.Split(strings.TrimPrefix(absolute, string(filepath.Separator)), string(filepath.Separator)) {
		if component == "" {
			continue
		}
		next, openErr := unix.Openat(
			fd,
			component,
			unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
			0,
		)
		_ = unix.Close(fd)
		if openErr != nil {
			return nil, openErr
		}
		fd = next
		currentName = filepath.Join(currentName, component)
	}
	file := os.NewFile(uintptr(fd), currentName)
	if file == nil {
		_ = unix.Close(fd)
		return nil, errLocalFileUnavailable
	}
	after, err := file.Stat()
	if err != nil || !os.SameFile(before, after) {
		_ = file.Close()
		return nil, errLocalFileUnavailable
	}
	return file, nil
}

func openLocalDirectoryAt(directory *os.File, name string) (*os.File, error) {
	if directory == nil || !safeLocalFileChildName(name) {
		return nil, errLocalFileUnavailable
	}
	fd, err := unix.Openat(
		int(directory.Fd()),
		name,
		unix.O_RDONLY|unix.O_DIRECTORY|unix.O_NOFOLLOW|unix.O_CLOEXEC,
		0,
	)
	if err != nil {
		return nil, err
	}
	file := os.NewFile(uintptr(fd), filepath.Join(directory.Name(), name))
	if file == nil {
		_ = unix.Close(fd)
		return nil, errLocalFileUnavailable
	}
	return file, nil
}

func validateLocalFileDirectory(directory *os.File) error {
	info, err := directory.Stat()
	if err != nil || !info.IsDir() || !localFileModePrivate(info.Mode()) {
		return errLocalFileUnavailable
	}
	return nil
}

func safeLocalFileChildName(name string) bool {
	return name != "" && name != "." && name != ".." &&
		!strings.ContainsAny(name, `/\\`) && !strings.ContainsRune(name, 0)
}
