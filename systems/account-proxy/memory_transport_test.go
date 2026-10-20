package accountproxy

import (
	"bytes"
	"errors"
	"io"
	"net/http"
	"sync"
	"time"
)

// bubbleStart is what time.Now() returns when a synctest bubble starts, so a
// fixture made before the bubble agrees with the clock the code reads in it.
var bubbleStart = time.Date(2000, time.January, 1, 0, 0, 0, 0, time.UTC)

// memoryTransport serves requests with a handler in memory, without a socket.
// A reader waiting for more of a response waits on a sync.Cond, which blocks
// durably in a synctest bubble, so the bubble's clock moves on to the deadline
// the test is about. Writes never wait for the reader, as on a socket.
type memoryTransport struct{ handler http.Handler }

func (m memoryTransport) RoundTrip(r *http.Request) (*http.Response, error) {
	w := &memoryResponse{header: http.Header{}, body: newMemoryBody(), started: make(chan struct{})}
	finished := make(chan struct{})
	go func() {
		defer close(finished)
		m.handler.ServeHTTP(w, r)
		w.WriteHeader(http.StatusOK)
		w.body.finish(io.EOF)
	}()
	// A server sees the request end when its client gives up.
	go func() {
		select {
		case <-r.Context().Done():
			w.body.finish(r.Context().Err())
		case <-finished:
		}
	}()
	select {
	case <-w.started:
		return &http.Response{StatusCode: w.status, Header: w.header, Body: w.body, Request: r}, nil
	case <-r.Context().Done():
		return nil, r.Context().Err()
	}
}

type memoryResponse struct {
	header  http.Header
	body    *memoryBody
	status  int
	once    sync.Once
	started chan struct{}
}

func (w *memoryResponse) Header() http.Header { return w.header }

func (w *memoryResponse) WriteHeader(status int) {
	w.once.Do(func() {
		w.status = status
		close(w.started)
	})
}

func (w *memoryResponse) Write(p []byte) (int, error) {
	w.WriteHeader(http.StatusOK)
	return w.body.write(p)
}

// Flush does nothing: the reader sees each write as it happens.
func (w *memoryResponse) Flush() {}

// memoryBody is a response body the handler writes and the client reads.
type memoryBody struct {
	mu      sync.Mutex
	changed *sync.Cond
	buf     bytes.Buffer
	end     error // io.EOF when the handler returned, or why the request ended
}

func newMemoryBody() *memoryBody {
	b := &memoryBody{}
	b.changed = sync.NewCond(&b.mu)
	return b
}

func (b *memoryBody) write(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.end != nil {
		return 0, errors.New("response closed")
	}
	b.buf.Write(p)
	b.changed.Broadcast()
	return len(p), nil
}

func (b *memoryBody) finish(err error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	if b.end == nil {
		b.end = err
		b.changed.Broadcast()
	}
}

func (b *memoryBody) Read(p []byte) (int, error) {
	b.mu.Lock()
	defer b.mu.Unlock()
	for b.buf.Len() == 0 && b.end == nil {
		b.changed.Wait()
	}
	if b.buf.Len() > 0 {
		return b.buf.Read(p)
	}
	return 0, b.end
}

func (b *memoryBody) Close() error {
	b.finish(errors.New("body closed"))
	return nil
}
