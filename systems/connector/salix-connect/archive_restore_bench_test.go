package main

import (
	"archive/tar"
	"bytes"
	"compress/gzip"
	"fmt"
	"io"
	"os"
	"path/filepath"
	"testing"
)

func BenchmarkArchiveTarGzManySmallFiles(b *testing.B) {
	const files = 2400
	root := b.TempDir()
	data := bytes.Repeat([]byte("x"), 512)
	for i := 0; i < files; i++ {
		if err := os.WriteFile(filepath.Join(root, fmt.Sprintf("file-%04d", i)), data, 0600); err != nil {
			b.Fatal(err)
		}
	}
	b.SetBytes(int64(files * len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := writeTarGz(io.Discard, root); err != nil {
			b.Fatal(err)
		}
	}
}

func BenchmarkRestoreTarGzManySmallFiles(b *testing.B) {
	const files = 2400
	var archive bytes.Buffer
	gz := gzip.NewWriter(&archive)
	tw := tar.NewWriter(gz)
	if err := tw.WriteHeader(&tar.Header{Name: "project/", Typeflag: tar.TypeDir, Mode: 0700}); err != nil {
		b.Fatal(err)
	}
	data := bytes.Repeat([]byte("x"), 512)
	for i := 0; i < files; i++ {
		if err := tw.WriteHeader(&tar.Header{Name: fmt.Sprintf("project/file-%04d", i), Mode: 0600, Size: int64(len(data))}); err != nil {
			b.Fatal(err)
		}
		if _, err := tw.Write(data); err != nil {
			b.Fatal(err)
		}
	}
	if err := tw.Close(); err != nil {
		b.Fatal(err)
	}
	if err := gz.Close(); err != nil {
		b.Fatal(err)
	}

	b.SetBytes(int64(files * len(data)))
	b.ResetTimer()
	for i := 0; i < b.N; i++ {
		if err := restoreTarGz(bytes.NewReader(archive.Bytes()), b.TempDir()); err != nil {
			b.Fatal(err)
		}
	}
}
