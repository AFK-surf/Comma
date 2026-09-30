package main

import (
	"context"
	"errors"
	"sync"
	"time"
)

const (
	webSocketControlQueueSize = 16
	webSocketDataQueueSize    = 64
)

var (
	errWebSocketClosed    = errors.New("websocket closed")
	errWebSocketQueueFull = errors.New("websocket write queue full")
)

type websocketJSONWriter interface {
	WriteJSON(any) error
	SetWriteDeadline(time.Time) error
	Close() error
}

type webSocketWrite struct {
	message     message
	result      chan error
	ctx         context.Context
	beforeWrite func()
}

// webSocketWriter is the single owner of WebSocket writes. Callers either wait
// for their bounded write to complete or enqueue an overload response without
// blocking the socket read loop.
type webSocketWriter struct {
	conn    websocketJSONWriter
	control chan webSocketWrite
	data    chan webSocketWrite
	done    chan struct{}

	closeOnce sync.Once
	err       error
}

func newWebSocketWriter(conn websocketJSONWriter) *webSocketWriter {
	w := &webSocketWriter{
		conn:    conn,
		control: make(chan webSocketWrite, webSocketControlQueueSize),
		data:    make(chan webSocketWrite, webSocketDataQueueSize),
		done:    make(chan struct{}),
	}
	go w.run()
	return w
}

func (w *webSocketWriter) SendContext(ctx context.Context, m message) error {
	return w.SendContextBeforeWrite(ctx, m, nil)
}

// SendContextBeforeWrite transfers request admission to the already-bounded
// write queue. The callback runs after queue admission and immediately before
// the frame can become visible on the wire.
func (w *webSocketWriter) SendContextBeforeWrite(ctx context.Context, m message, beforeWrite func()) error {
	req := webSocketWrite{
		message:     m,
		result:      make(chan error, 1),
		ctx:         ctx,
		beforeWrite: beforeWrite,
	}
	queue := w.queueFor(m)
	select {
	case queue <- req:
	case <-ctx.Done():
		return ctx.Err()
	case <-w.done:
		return w.closeError()
	}

	select {
	case err := <-req.result:
		return err
	case <-ctx.Done():
		return ctx.Err()
	case <-w.done:
		return w.closeError()
	}
}

// Enqueue never waits for queue capacity. It is used by the reader when a
// bounded worker pool is saturated; a full outbound queue is treated as a
// failed connection rather than allowing the reader itself to stall.
func (w *webSocketWriter) Enqueue(m message) error {
	select {
	case <-w.done:
		return w.closeError()
	default:
	}

	select {
	case w.queueFor(m) <- webSocketWrite{message: m}:
		select {
		case <-w.done:
			return w.closeError()
		default:
			return nil
		}
	default:
		return errWebSocketQueueFull
	}
}

func (w *webSocketWriter) Close(err error) {
	if err == nil {
		err = errWebSocketClosed
	}
	w.closeOnce.Do(func() {
		w.err = err
		close(w.done)
		_ = w.conn.Close()
	})
}

func (w *webSocketWriter) run() {
	for {
		var req webSocketWrite
		select {
		case req = <-w.control:
		default:
			select {
			case req = <-w.control:
			case req = <-w.data:
			case <-w.done:
				return
			}
		}
		select {
		case <-w.done:
			w.complete(req, w.closeError())
			return
		default:
		}
		if req.ctx != nil {
			select {
			case <-req.ctx.Done():
				w.complete(req, req.ctx.Err())
				continue
			default:
			}
		}

		if err := w.conn.SetWriteDeadline(time.Now().Add(webSocketWriteTimeout)); err != nil {
			w.complete(req, err)
			w.Close(err)
			return
		}
		// The release-before-reply linearization point is modeled in
		// tla/connector/ConnectorRequestAdmission.tla.
		if req.beforeWrite != nil {
			req.beforeWrite()
		}
		err := w.conn.WriteJSON(req.message)
		w.complete(req, err)
		if err != nil {
			w.Close(err)
			return
		}
	}
}

func (w *webSocketWriter) queueFor(m message) chan webSocketWrite {
	if m.Type == "heartbeat" || m.Type == "metadata" {
		return w.control
	}
	return w.data
}

func (w *webSocketWriter) complete(req webSocketWrite, err error) {
	if req.result != nil {
		req.result <- err
	}
}

func (w *webSocketWriter) closeError() error {
	if w.err == nil {
		return errWebSocketClosed
	}
	return w.err
}
