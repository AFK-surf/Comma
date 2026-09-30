package main

import (
	"context"
	"errors"
	"net/url"
	"sync/atomic"
	"time"
)

// The compressor writes one ordered byte stream. Complete parts are uploaded
// concurrently, with at most eight parts retained in memory at once.
type signedArchiveUploadWriter struct {
	ctx       context.Context
	cancel    context.CancelFunc
	transfers []signedArchiveTransfer
	buffer    []byte
	index     int
	pending   []<-chan error
	uploaded  atomic.Int64
	putNS     atomic.Int64
	waitNS    atomic.Int64
	written   int64
}

func newSignedArchiveUploadWriter(parent context.Context, transfers []signedArchiveTransfer) (*signedArchiveUploadWriter, error) {
	if len(transfers) == 0 || len(transfers) > 1024 {
		return nil, errors.New("invalid archive upload targets")
	}
	for _, transfer := range transfers {
		if validateSignedArchiveURL(transfer.PutURL) != nil || validateSignedArchiveURL(transfer.GetURL) != nil {
			return nil, errors.New("invalid signed archive upload URL")
		}
		putTarget, _ := url.Parse(transfer.PutURL)
		getTarget, _ := url.Parse(transfer.GetURL)
		if putTarget.Host != getTarget.Host || putTarget.EscapedPath() != getTarget.EscapedPath() {
			return nil, errors.New("archive transfer targets differ")
		}
	}
	ctx, cancel := context.WithCancel(parent)
	return &signedArchiveUploadWriter{ctx: ctx, cancel: cancel, transfers: transfers, buffer: make([]byte, 0, providerMigrationChunkSize)}, nil
}

func (w *signedArchiveUploadWriter) Write(p []byte) (int, error) {
	consumed := 0
	for len(p) != 0 {
		if err := w.ctx.Err(); err != nil {
			return consumed, err
		}
		n := copy(w.buffer[len(w.buffer):cap(w.buffer)], p)
		w.buffer = w.buffer[:len(w.buffer)+n]
		w.written += int64(n)
		consumed += n
		p = p[n:]
		if len(w.buffer) == providerMigrationChunkSize {
			if err := w.dispatch(); err != nil {
				return consumed, err
			}
		}
	}
	return consumed, nil
}

func (w *signedArchiveUploadWriter) dispatch() error {
	if w.index >= len(w.transfers) {
		return errors.New("archive exceeds signed upload part count")
	}
	if len(w.pending) == 8 {
		waitStarted := time.Now()
		if err := <-w.pending[0]; err != nil {
			w.cancel()
			return err
		}
		w.waitNS.Add(time.Since(waitStarted).Nanoseconds())
		w.pending = w.pending[1:]
	}
	part := w.buffer
	transfer := w.transfers[w.index]
	w.index++
	result := make(chan error, 1)
	w.pending = append(w.pending, result)
	go func() {
		started := time.Now()
		err := putSignedArchiveChunk(w.ctx, transfer.PutURL, transfer.GetURL, part)
		w.putNS.Add(time.Since(started).Nanoseconds())
		if err == nil {
			w.uploaded.Add(int64(len(part)))
		}
		result <- err
	}()
	w.buffer = make([]byte, 0, providerMigrationChunkSize)
	return nil
}

func (w *signedArchiveUploadWriter) Close() error {
	if len(w.buffer) > 0 {
		if err := w.dispatch(); err != nil {
			return err
		}
	}
	for _, result := range w.pending {
		if err := <-result; err != nil {
			w.cancel()
			return err
		}
	}
	w.cancel()
	if w.uploaded.Load() != w.written {
		return errors.New("archive upload incomplete")
	}
	return nil
}

func (w *signedArchiveUploadWriter) Cancel() { w.cancel() }
