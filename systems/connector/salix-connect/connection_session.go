package main

import (
	"context"
	"errors"
	"fmt"
	"io"
	"strings"
	"sync"
	"time"
)

const (
	connectionDrainTimeout  = 5 * time.Second
	requestExecutionSlop    = 5 * time.Second
	cleanupQueueSize        = 64
	scopeAbortNotifyTimeout = 2 * time.Second
)

var (
	requestExecutionTimeout   = 2 * time.Minute
	errConnectionWorkersStuck = errors.New("connection workers did not stop after cancellation")
	errWriteStreamClosed      = errors.New("write stream is closed")
)

type contextMessageSender func(context.Context, message) error
type requestReplySender func(context.Context, message, func()) error

type connectorFatalError struct {
	err error
}

func (e connectorFatalError) Error() string { return e.err.Error() }
func (e connectorFatalError) Unwrap() error { return e.err }

// connectionSession owns transport-local state for one WebSocket generation.
// Request admission belongs to the connector; stream and reply-sink state do
// not survive into a replacement socket.
type connectionSession struct {
	connector *connector
	ownerCtx  context.Context
	ctx       context.Context
	cancel    context.CancelFunc
	sendCtx   contextMessageSender
	sendReply requestReplySender
	closeWire func(error)
	deadline  func(message) time.Duration

	streamSlots  chan struct{}
	tasks        sync.WaitGroup
	lifecycleMu  sync.Mutex
	closed       bool
	closedSignal chan struct{}

	pendingMu     sync.Mutex
	pendingWrites map[string]*pendingWrite
	pendingAcks   map[string]chan string
	closeOnce     sync.Once
}

type pendingWrite struct {
	stateMu sync.Mutex
	writeMu sync.Mutex
	file    io.WriteCloser
	closed  bool
	size    int64
}

func newConnectionSession(
	c *connector,
	parent context.Context,
	send contextMessageSender,
	closeWire func(error),
) *connectionSession {
	ctx, cancel := context.WithCancel(parent)
	session := &connectionSession{
		connector:     c,
		ownerCtx:      parent,
		ctx:           ctx,
		cancel:        cancel,
		sendCtx:       send,
		closeWire:     closeWire,
		deadline:      requestTimeout,
		streamSlots:   make(chan struct{}, maxConcurrentStreamWrites),
		pendingWrites: map[string]*pendingWrite{},
		pendingAcks:   map[string]chan string{},
		closedSignal:  make(chan struct{}),
	}
	if closeWire != nil && parent.Done() != nil {
		go func() {
			select {
			case <-parent.Done():
				session.close(parent.Err())
			case <-session.closedSignal:
			}
		}()
	}
	return session
}

func (c *connector) claimConnection(
	parent context.Context,
	send contextMessageSender,
	closeWire func(error),
) *connectionSession {
	c.connectionMu.Lock()
	session := newConnectionSession(c, parent, send, closeWire)
	previous := c.activeConnection
	if previous != nil {
		previous.close(errors.New("connection replaced"))
	}
	c.activeConnection = session
	// A replacement socket has no authority until its own connected frame is
	// observed. Never let it inherit the previous generation's read_ref tuple.
	c.connectorRunID = ""
	c.deviceID = ""
	c.connectorID = ""
	c.ownerUserID = ""
	c.connectionGeneration = 0
	c.connectionMu.Unlock()

	if previous != nil && c.afterConnectionPublished != nil {
		c.afterConnectionPublished(previous)
	}
	return session
}

func (c *connector) releaseConnection(session *connectionSession) {
	c.connectionMu.Lock()
	if c.activeConnection == session {
		c.activeConnection = nil
	}
	c.connectionMu.Unlock()
}

func (c *connector) connectionActive(session *connectionSession) bool {
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	return c.activeConnection == session
}

func (c *connector) setIdentity(
	session *connectionSession,
	connectorRunID, deviceID, connectorID, ownerUserID string,
	connectionGeneration int64,
) bool {
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	if session != nil && c.activeConnection != session {
		return false
	}
	c.connectorRunID = connectorRunID
	c.deviceID = deviceID
	c.connectorID = connectorID
	c.ownerUserID = ownerUserID
	c.connectionGeneration = connectionGeneration
	return true
}

func (c *connector) localFileConnectionIdentity() (string, string, string, int64) {
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	return c.connectorRunID, c.deviceID, c.ownerUserID, c.connectionGeneration
}

func (c *connector) connectionIdentity() (string, string, string) {
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	return c.connectorRunID, c.deviceID, c.connectorID
}

func (s *connectionSession) send(m message) error {
	return s.sendCtx(s.ctx, m)
}

func (s *connectionSession) sendRequestReply(m message, beforeWrite func()) error {
	// Request admission must be released before reply visibility; the bounded
	// ordering is modeled in tla/connector/ConnectorRequestAdmission.tla.
	if s.sendReply == nil {
		beforeWrite()
		return s.sendCtx(s.ctx, m)
	}
	return s.sendReply(s.ctx, m, beforeWrite)
}

func (s *connectionSession) newRequestAdmissionRelease() func() {
	return sync.OnceFunc(func() { <-s.connector.requestSlots })
}

func (s *connectionSession) close(reason error) {
	s.closeOnce.Do(func() {
		s.lifecycleMu.Lock()
		s.closed = true
		s.lifecycleMu.Unlock()
		close(s.closedSignal)
		s.cancel()
		if s.closeWire != nil {
			s.closeWire(reason)
		}
		s.abortPendingTransfers(defaultString(errorText(reason), "connection closed"))
	})
}

func (s *connectionSession) wait() bool {
	done := make(chan struct{})
	go func() {
		s.tasks.Wait()
		close(done)
	}()
	select {
	case <-done:
		return true
	case <-time.After(connectionDrainTimeout):
		return false
	}
}

func (s *connectionSession) startRequest(msg message, after func()) bool {
	if s.connector.beforeRequestAdmission != nil {
		s.connector.beforeRequestAdmission(s, msg)
	}
	if !recoverableRequest(msg) {
		return s.startConnectionRequest(msg, after)
	}
	fingerprint, err := requestFingerprint(msg)
	if err != nil {
		return s.startRequestReply(message{
			ID:    msg.ID,
			Type:  "error",
			Error: fmt.Sprintf("%s: invalid request params: %v", msg.Method, err),
		})
	}
	binding, reply := s.connector.bindRequestOperation(s, msg, fingerprint)
	switch binding {
	case requestExecute:
		go func() {
			releaseAdmission := s.newRequestAdmissionRelease()
			defer releaseAdmission()
			if after != nil {
				defer after()
			}
			defer func() {
				if recovered := recover(); recovered != nil {
					s.connector.completeRequestOperation(msg.ID, msg.Method, message{
						ID:    msg.ID,
						Type:  "error",
						Error: fmt.Sprintf("%s: connector request panic: %v", msg.Method, recovered),
					}, releaseAdmission)
				}
			}()
			ctx, cancel := context.WithTimeout(s.ownerCtx, s.deadline(msg))
			defer cancel()
			reply := s.connector.requestReply(ctx, s, msg)
			s.connector.completeRequestOperation(msg.ID, msg.Method, reply, releaseAdmission)
		}()
		return true
	case requestRebound:
		return true
	case requestReply:
		go func() {
			releaseAdmission := s.newRequestAdmissionRelease()
			defer releaseAdmission()
			_ = s.sendRequestReply(reply, releaseAdmission)
		}()
		return true
	default:
		return false
	}
}

func (s *connectionSession) startRequestReply(reply message) bool {
	if !s.admitRequest() {
		return false
	}
	go func() {
		releaseAdmission := s.newRequestAdmissionRelease()
		defer releaseAdmission()
		_ = s.sendRequestReply(reply, releaseAdmission)
	}()
	return true
}

func (s *connectionSession) startConnectionRequest(msg message, after func()) bool {
	if !s.admitRequest() {
		return false
	}
	go func() {
		releaseAdmission := s.newRequestAdmissionRelease()
		defer releaseAdmission()
		if after != nil {
			defer after()
		}
		defer func() {
			if recovered := recover(); recovered != nil {
				_ = s.sendRequestReply(message{
					ID:    msg.ID,
					Type:  "error",
					Error: fmt.Sprintf("%s: connector request panic: %v", msg.Method, recovered),
				}, releaseAdmission)
			}
		}()
		ctx, cancel := context.WithTimeout(s.ownerCtx, s.deadline(msg))
		defer cancel()
		_ = s.sendRequestReply(s.connector.requestReply(ctx, s, msg), releaseAdmission)
	}()
	return true
}

func (s *connectionSession) admitRequest() bool {
	s.connector.connectionMu.Lock()
	defer s.connector.connectionMu.Unlock()
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	if (s.connector.activeConnection != nil && s.connector.activeConnection != s) || s.closed {
		return false
	}
	select {
	case s.connector.requestSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (s *connectionSession) startStream(msg message, after func()) bool {
	if !s.admit(s.streamSlots) {
		return false
	}
	go func() {
		defer s.tasks.Done()
		defer func() { <-s.streamSlots }()
		if after != nil {
			defer after()
		}
		defer func() {
			if recovered := recover(); recovered != nil {
				s.finishPendingWrite(msg.ID)
				_ = s.send(message{
					ID:     msg.ID,
					Type:   "stream",
					Error:  fmt.Sprintf("connector stream panic: %v", recovered),
					Stream: &streamData{Channel: "done", EOF: true},
				})
			}
		}()
		s.handleStream(msg)
	}()
	return true
}

func (s *connectionSession) admit(slots chan struct{}) bool {
	s.connector.connectionMu.Lock()
	defer s.connector.connectionMu.Unlock()
	s.lifecycleMu.Lock()
	defer s.lifecycleMu.Unlock()
	if (s.connector.activeConnection != nil && s.connector.activeConnection != s) || s.closed {
		return false
	}
	select {
	case slots <- struct{}{}:
		s.tasks.Add(1)
		return true
	default:
		return false
	}
}

func requestTimeout(msg message) time.Duration {
	if msg.Method == "android" {
		// Profile switching and cleanup finish within 200 seconds.
		// Leave transport headroom inside the Server's 220-second timeout.
		return 210 * time.Second
	}
	if msg.Method == "runtime_probe" || strings.HasPrefix(msg.Method, "runtime_auth_") {
		return 30 * time.Second
	}
	if msg.Method == "meeting_artifact_read" {
		return meetingArtifactRequestTimeout(msg.Params)
	}
	if msg.Method == "read_ref" {
		return time.Minute
	}
	timeout := requestExecutionTimeout
	seconds := 0
	switch msg.Method {
	case "exec":
		seconds = intParam(msg.Params, "timeout", 0)
	case "http_request":
		seconds = intParam(msg.Params, "timeout_seconds", 0)
	case "process_tail":
		seconds = intParam(msg.Params, "wait_seconds", 0)
	}
	if seconds <= 0 {
		return timeout
	}
	maxSeconds := int((time.Duration(1<<63-1) - requestExecutionSlop) / time.Second)
	if seconds >= maxSeconds {
		return time.Duration(1<<63 - 1)
	}
	requested := time.Duration(seconds)*time.Second + requestExecutionSlop
	if requested > timeout {
		return requested
	}
	return timeout
}

func (s *connectionSession) reservePendingWrite(id string) (*pendingWrite, error) {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()
	if _, exists := s.pendingWrites[id]; exists {
		return nil, errors.New("write_stream already exists")
	}
	if len(s.pendingWrites) >= maxPendingWriteStreams {
		return nil, errors.New("write_stream capacity exhausted")
	}
	pending := &pendingWrite{}
	s.pendingWrites[id] = pending
	return pending, nil
}

func (s *connectionSession) activatePendingWrite(id string, pending *pendingWrite, file io.WriteCloser) bool {
	s.pendingMu.Lock()
	active := s.pendingWrites[id] == pending
	s.pendingMu.Unlock()
	if !active || !pending.setFile(file) {
		s.connector.enqueueCleanup(file)
		return false
	}
	return true
}

func (s *connectionSession) pendingWrite(id string) *pendingWrite {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()
	return s.pendingWrites[id]
}

func (s *connectionSession) detachPendingWrite(id string) *pendingWrite {
	s.pendingMu.Lock()
	defer s.pendingMu.Unlock()
	pending := s.pendingWrites[id]
	if pending == nil {
		return nil
	}
	delete(s.pendingWrites, id)
	return pending
}

func (s *connectionSession) finishPendingWrite(id string) {
	if pending := s.detachPendingWrite(id); pending != nil {
		s.connector.enqueueCleanup(pending)
	}
}

func (s *connectionSession) abortPendingWrite(id string) {
	if pending := s.detachPendingWrite(id); pending != nil {
		s.connector.enqueueCleanup(pending.abort())
	}
}

// abortPendingWritesForScope synchronously removes every write authority, then
// reports terminal cancellation on the transport without putting user-owned
// Close latency on the scope-control loop.
func (s *connectionSession) abortPendingWritesForScope(reason string) {
	s.pendingMu.Lock()
	writes := s.pendingWrites
	s.pendingWrites = map[string]*pendingWrite{}
	s.pendingMu.Unlock()

	ids := make([]string, 0, len(writes))
	for id, pending := range writes {
		ids = append(ids, id)
		s.connector.enqueueCleanup(pending.abort())
	}
	if len(ids) == 0 {
		return
	}
	go func() {
		ctx, cancel := context.WithTimeout(s.ctx, scopeAbortNotifyTimeout)
		defer cancel()
		for _, id := range ids {
			_ = s.sendCtx(ctx, message{
				ID:    id,
				Type:  "stream",
				Error: reason,
				Stream: &streamData{
					Channel: "done",
					EOF:     true,
				},
			})
		}
	}()
}

func (s *connectionSession) abortPendingTransfers(reason string) {
	s.pendingMu.Lock()
	writes := s.pendingWrites
	acks := s.pendingAcks
	s.pendingWrites = map[string]*pendingWrite{}
	s.pendingAcks = map[string]chan string{}
	s.pendingMu.Unlock()

	for _, pending := range writes {
		s.connector.enqueueCleanup(pending.abort())
	}
	for _, ack := range acks {
		select {
		case ack <- reason:
		default:
		}
	}
}

func (p *pendingWrite) setFile(file io.WriteCloser) bool {
	p.stateMu.Lock()
	defer p.stateMu.Unlock()
	if p.closed {
		return false
	}
	p.file = file
	return true
}

func (p *pendingWrite) write(data []byte) (int64, error) {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	p.stateMu.Lock()
	file := p.file
	closed := p.closed
	p.stateMu.Unlock()
	if closed || file == nil {
		return p.size, errWriteStreamClosed
	}
	if _, err := file.Write(data); err != nil {
		return p.size, err
	}
	p.size += int64(len(data))
	return p.size, nil
}

func (p *pendingWrite) currentSize() int64 {
	p.writeMu.Lock()
	defer p.writeMu.Unlock()
	return p.size
}

func (p *pendingWrite) Close() error {
	file := p.abort()
	if file != nil {
		return file.Close()
	}
	return nil
}

// abort flips the in-memory gate synchronously and returns the user-owned
// file for bounded asynchronous cleanup. A downgrade must not wait on a FIFO,
// device, or other WriteCloser whose Close implementation can stall.
func (p *pendingWrite) abort() io.WriteCloser {
	p.stateMu.Lock()
	if p.closed {
		p.stateMu.Unlock()
		return nil
	}
	p.closed = true
	file := p.file
	p.file = nil
	p.stateMu.Unlock()
	return file
}

func (c *connector) enqueueCleanup(closer io.Closer) {
	if closer == nil {
		return
	}
	select {
	case c.cleanupQueue <- closer:
	default:
		c.reportFatal(errors.New("connector cleanup queue exhausted"))
	}
}

func (c *connector) cleanupLoop() {
	for closer := range c.cleanupQueue {
		_ = closer.Close()
	}
}

func (c *connector) reportFatal(err error) {
	if err == nil {
		return
	}
	if !isConnectorFatal(err) {
		err = connectorFatalError{err: err}
	}
	c.fatalOnce.Do(func() {
		c.fatalMu.Lock()
		c.fatalErr = err
		c.fatalMu.Unlock()
		close(c.fatalSignal)
		select {
		case c.fatalErrors <- err:
		default:
		}
	})
}

func isConnectorFatal(err error) bool {
	var fatal connectorFatalError
	return errors.As(err, &fatal)
}

func (c *connector) connectorFatal() error {
	c.fatalMu.Lock()
	defer c.fatalMu.Unlock()
	return c.fatalErr
}

func errorText(err error) string {
	if err == nil {
		return ""
	}
	return err.Error()
}
