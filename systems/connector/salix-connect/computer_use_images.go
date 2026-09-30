package main

import (
	"encoding/base64"
	"errors"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"strings"
	"time"
)

// Screenshots are temporary device artifacts. Only this directory is disposable.
// Reads and expiry share a lock so expiry cannot remove a file during a read.
const computerUseImageTTL = 15 * time.Minute
const computerUseImageMaxBytes = 5 * 1024 * 1024
const computerUseImageBudget = 128 * 1024 * 1024
const computerUseImageMaxCount = 128

func (c *connector) computerUseImageDirectory() (string, error) {
	if c.cfg.computerUseRuntimePath == "" {
		return "", errors.New("computer_use temporary storage is not configured")
	}
	dir := filepath.Join(c.cfg.computerUseRuntimePath, "screenshots")
	if err := os.MkdirAll(dir, 0700); err != nil {
		return "", err
	}
	return dir, nil
}

func computerUseImageName(name string) bool {
	return filepath.Base(name) == name && strings.HasPrefix(name, "capture-") && (strings.HasSuffix(name, ".png") || strings.HasSuffix(name, ".jpg"))
}

func (c *connector) expireComputerUseImage(path string, delay time.Duration) {
	time.AfterFunc(delay, func() {
		c.computerUseImageMu.Lock()
		defer c.computerUseImageMu.Unlock()
		if err := os.Remove(path); err != nil && !os.IsNotExist(err) {
			logf("computer_use screenshot expiry failed: %v", err)
		}
	})
}

// Scan only the bounded, private screenshot directory, and leave foreign files alone.
func (c *connector) sweepComputerUseImages(dir string) (int64, int, error) {
	f, err := os.Open(dir)
	if err != nil {
		return 0, 0, err
	}
	defer f.Close()
	entries, err := f.ReadDir(computerUseImageMaxCount + 1)
	if err != nil && !errors.Is(err, io.EOF) {
		return 0, 0, err
	}
	if len(entries) > computerUseImageMaxCount {
		return 0, 0, errors.New("computer_use screenshot storage is full")
	}
	var size int64
	count := 0
	type expiry struct {
		path  string
		delay time.Duration
	}
	var pending []expiry
	for _, entry := range entries {
		if !computerUseImageName(entry.Name()) || !entry.Type().IsRegular() {
			return 0, 0, errors.New("unexpected file in computer_use screenshot storage")
		}
		info, err := entry.Info()
		if err != nil {
			return 0, 0, err
		}
		path := filepath.Join(dir, entry.Name())
		remaining := time.Until(info.ModTime().Add(computerUseImageTTL))
		if remaining <= 0 {
			if err := os.Remove(path); err != nil {
				return 0, 0, err
			}
		} else {
			size += info.Size()
			count++
			if !c.computerUseImagesScheduled {
				pending = append(pending, expiry{path, remaining})
			}
		}
	}
	for _, item := range pending {
		c.expireComputerUseImage(item.path, item.delay)
	}
	c.computerUseImagesScheduled = true
	return size, count, nil
}

func (c *connector) storeComputerUseImage(response computerUseDaemonResponse) (map[string]any, error) {
	c.computerUseImageMu.Lock()
	defer c.computerUseImageMu.Unlock()
	if len(response.ImageData) > computerUseImageMaxBytes {
		return nil, errors.New("computer_use screenshot exceeds 5 MiB")
	}
	ext, mime := ".png", response.ImageContentType
	switch mime {
	case "image/png":
	case "image/jpeg":
		ext = ".jpg"
	default:
		return nil, errors.New("unsupported screenshot format")
	}
	dir, err := c.computerUseImageDirectory()
	if err != nil {
		return nil, err
	}
	used, count, err := c.sweepComputerUseImages(dir)
	if err != nil {
		return nil, err
	}
	if count >= computerUseImageMaxCount || used+int64(len(response.ImageData)) > computerUseImageBudget {
		return nil, errors.New("computer_use screenshot storage is full; retry after screenshots expire")
	}
	f, err := os.CreateTemp(dir, "capture-*"+ext)
	if err != nil {
		return nil, err
	}
	path := f.Name()
	_, writeErr := f.Write(response.ImageData)
	closeErr := f.Close()
	if writeErr != nil || closeErr != nil {
		_ = os.Remove(path)
		return nil, fmt.Errorf("save screenshot: %v %v", writeErr, closeErr)
	}
	c.expireComputerUseImage(path, computerUseImageTTL)
	return map[string]any{"ok": true, "image_path": filepath.Base(path), "image_content_type": mime, "image_width": response.ImageWidth, "image_height": response.ImageHeight, "image_size_bytes": len(response.ImageData)}, nil
}

func (c *connector) readComputerUseImage(name string) map[string]any {
	c.computerUseImageMu.Lock()
	defer c.computerUseImageMu.Unlock()
	if !computerUseImageName(name) {
		return computerUseError("invalid screenshot reference")
	}
	dir, err := c.computerUseImageDirectory()
	if err != nil {
		return computerUseError(err.Error())
	}
	if _, _, err := c.sweepComputerUseImages(dir); err != nil {
		return computerUseError(err.Error())
	}
	path := filepath.Join(dir, name)
	info, err := os.Lstat(path)
	if err != nil || !info.Mode().IsRegular() {
		return computerUseError("screenshot expired or unavailable")
	}
	if info.Size() > computerUseImageMaxBytes {
		return computerUseError("screenshot exceeds 5 MiB")
	}
	f, err := os.Open(path)
	if err != nil {
		return computerUseError("screenshot unavailable")
	}
	defer f.Close()
	body, err := io.ReadAll(io.LimitReader(f, computerUseImageMaxBytes+1))
	if err != nil {
		return computerUseError("screenshot unavailable")
	}
	if len(body) > computerUseImageMaxBytes {
		return computerUseError("screenshot exceeds 5 MiB")
	}
	return map[string]any{"ok": true, "image_base64": base64.StdEncoding.EncodeToString(body)}
}
