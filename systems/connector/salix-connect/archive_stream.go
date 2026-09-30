package main

import (
	"context"
	"errors"
	"io"
	"sync"
	"sync/atomic"
	"time"
)

// Each signed URL identifies one existing archive part. The reader fetches a
// bounded window in parallel and supplies bytes to the decoder in tar order.
type signedArchivePart struct {
	SourceURL string `json:"source_url"`
	Bytes     int64  `json:"bytes"`
}

type signedArchiveResult struct {
	data []byte
	err  error
}

type parallelSignedArchiveReader struct {
	ctx        context.Context
	cancel     context.CancelFunc
	parts      []signedArchivePart
	results    []chan signedArchiveResult
	jobs       chan int
	workers    sync.WaitGroup
	next       int
	current    []byte
	downloaded int64
	fetchNS    atomic.Int64
	waitNS     atomic.Int64
}

func newParallelSignedArchiveReader(parent context.Context, parts []signedArchivePart, concurrency int) (*parallelSignedArchiveReader, error) {
	if concurrency < 1 || len(parts) == 0 || len(parts) > 1024 {
		return nil, errors.New("invalid archive part count")
	}
	for _, part := range parts {
		if part.Bytes < 1 || part.Bytes > providerMigrationChunkSize || validateSignedArchiveURL(part.SourceURL) != nil {
			return nil, errors.New("invalid signed archive part")
		}
	}
	ctx, cancel := context.WithCancel(parent)
	r := &parallelSignedArchiveReader{
		ctx: ctx, cancel: cancel, parts: parts,
		results: make([]chan signedArchiveResult, len(parts)),
		jobs:    make(chan int, concurrency),
	}
	for i := range r.results {
		r.results[i] = make(chan signedArchiveResult, 1)
	}
	for range concurrency {
		r.workers.Add(1)
		go func() {
			defer r.workers.Done()
			for {
				select {
				case <-ctx.Done():
					return
				case index := <-r.jobs:
					part := parts[index]
					started := time.Now()
					data, err := readSignedArchiveChunk(ctx, part.SourceURL, part.Bytes)
					r.fetchNS.Add(time.Since(started).Nanoseconds())
					select {
					case r.results[index] <- signedArchiveResult{data: data, err: err}:
					case <-ctx.Done():
						return
					}
				}
			}
		}()
	}
	for i := 0; i < len(parts) && i < concurrency; i++ {
		r.jobs <- i
	}
	return r, nil
}

func (r *parallelSignedArchiveReader) Read(p []byte) (int, error) {
	if len(p) == 0 {
		return 0, nil
	}
	for len(r.current) == 0 {
		if r.next == len(r.parts) {
			return 0, io.EOF
		}
		waitStarted := time.Now()
		select {
		case <-r.ctx.Done():
			return 0, r.ctx.Err()
		case result := <-r.results[r.next]:
			r.waitNS.Add(time.Since(waitStarted).Nanoseconds())
			if result.err != nil {
				return 0, result.err
			}
			r.current = result.data
			r.downloaded += int64(len(result.data))
			r.next++
			if following := r.next + cap(r.jobs) - 1; following < len(r.parts) {
				select {
				case r.jobs <- following:
				case <-r.ctx.Done():
					return 0, r.ctx.Err()
				}
			}
		}
	}
	n := copy(p, r.current)
	r.current = r.current[n:]
	return n, nil
}

func (r *parallelSignedArchiveReader) Close() {
	r.cancel()
	r.workers.Wait()
}
