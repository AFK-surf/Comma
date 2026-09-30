package main

import (
	"crypto/sha256"
	"encoding/json"
	"fmt"
	"reflect"
	"time"
)

const (
	requestReplayTTL        = 2 * time.Minute
	requestReplayMaxEntries = 256
	requestReplayMaxBytes   = 32 * 1024 * 1024
)

type requestOperation struct {
	fingerprint     [sha256.Size]byte
	sink            *connectionSession
	reply           message
	replyBytes      int
	completedAt     time.Time
	done            bool
	replayCompleted bool
}

type requestBinding uint8

const (
	requestRejected requestBinding = iota
	requestExecute
	requestRebound
	requestReply
)

func recoverableRequest(msg message) bool {
	return msg.ID != "" && msg.Method != "android" && msg.Method != "read_stream" && msg.Method != "read_ref" && msg.Method != "write_stream" && msg.Method != "meeting_artifact_read"
}

func requestFingerprint(msg message) ([sha256.Size]byte, error) {
	params, err := json.Marshal(msg.Params)
	if err != nil {
		return [sha256.Size]byte{}, err
	}
	payload := append(append([]byte(msg.Method), 0), params...)
	return sha256.Sum256(payload), nil
}

func (c *connector) bindRequestOperation(
	session *connectionSession,
	msg message,
	fingerprint [sha256.Size]byte,
) (requestBinding, message) {
	c.connectionMu.Lock()
	defer c.connectionMu.Unlock()
	session.lifecycleMu.Lock()
	defer session.lifecycleMu.Unlock()
	if (c.activeConnection != nil && c.activeConnection != session) || session.closed {
		return requestRejected, message{}
	}

	c.requestMu.Lock()
	defer c.requestMu.Unlock()
	c.pruneRequestOperationsLocked(time.Now(), "")

	if operation := c.requestOperations[msg.ID]; operation != nil {
		if operation.fingerprint != fingerprint {
			if !c.takeRequestSlot() {
				return requestRejected, message{}
			}
			return requestReply, message{
				ID:    msg.ID,
				Type:  "error",
				Error: "request id reused with different method or params",
			}
		}
		if operation.done {
			if !c.takeRequestSlot() {
				return requestRejected, message{}
			}
			if operation.replayCompleted {
				return requestReply, operation.reply
			}
			// Sensitive completed results retain only their fingerprint tombstone.
			// Re-execute the request through its domain-level idempotency fence rather
			// than replaying ceremony data after the attempt became terminal.
			c.requestOperations[msg.ID] = &requestOperation{
				fingerprint: fingerprint,
				sink:        session,
			}
			return requestExecute, message{}
		}
		operation.sink = session
		return requestRebound, message{}
	}

	if !c.takeRequestSlot() {
		return requestRejected, message{}
	}
	c.requestOperations[msg.ID] = &requestOperation{
		fingerprint: fingerprint,
		sink:        session,
	}
	return requestExecute, message{}
}

func (c *connector) takeRequestSlot() bool {
	select {
	case c.requestSlots <- struct{}{}:
		return true
	default:
		return false
	}
}

func (c *connector) completeRequestOperation(id, method string, reply message, beforeWrite func()) {
	if beforeWrite == nil {
		beforeWrite = func() {}
	}
	replayCompleted := replayCompletedRequest(method)
	replyBytes := 0
	if replayCompleted {
		reply, replyBytes = boundedReplayReply(id, method, reply)
	}

	c.requestMu.Lock()
	operation := c.requestOperations[id]
	if operation == nil || operation.done {
		c.requestMu.Unlock()
		beforeWrite()
		return
	}
	operation.done = true
	operation.replayCompleted = replayCompleted
	if replayCompleted {
		operation.reply = reply
		operation.replyBytes = replyBytes
	}
	operation.completedAt = time.Now()
	c.requestReplayBytes += replyBytes
	sink := operation.sink
	c.pruneRequestOperationsLocked(operation.completedAt, id)
	c.requestMu.Unlock()

	if sink != nil {
		_ = sink.sendRequestReply(reply, beforeWrite)
	} else {
		beforeWrite()
	}
}

func replayCompletedRequest(method string) bool {
	// Device-code start replies contain a verification URL and one-time code.
	// Keep the running operation rebindable across a socket replacement, but do
	// not retain its completed reply outside runtimeAuthCoordinator's exact attempt
	// fence. A retry executes the manager again and either reuses the still-live
	// attempt or observes its terminal state.
	return method != "runtime_auth_login_start"
}

func boundedReplayReply(id, method string, reply message) (message, int) {
	replyBytes := estimateReplyBytes(reply)
	if replyBytes <= requestReplayMaxBytes {
		return reply, max(replyBytes, 1)
	}
	reply = message{
		ID:    id,
		Type:  "error",
		Error: fmt.Sprintf("%s: response exceeds connector replay limit", method),
	}
	return reply, estimateReplyBytes(reply)
}

// estimateReplyBytes walks the already-built result without serializing or
// copying it. Exact JSON punctuation is irrelevant to the cache budget; string
// and byte payloads dominate, while the entry cap bounds container overhead.
func estimateReplyBytes(reply message) int {
	size := len(reply.ID) + len(reply.Type) + len(reply.Error)
	return size + estimateValueBytes(reflect.ValueOf(reply.Result), requestReplayMaxBytes-size, 0)
}

func estimateValueBytes(value reflect.Value, remaining, depth int) int {
	if !value.IsValid() || remaining <= 0 {
		return 0
	}
	if depth > 64 {
		return remaining + 1
	}
	for value.Kind() == reflect.Interface || value.Kind() == reflect.Pointer {
		if value.IsNil() {
			return 0
		}
		value = value.Elem()
	}
	switch value.Kind() {
	case reflect.String:
		return value.Len()
	case reflect.Slice, reflect.Array:
		if value.Type().Elem().Kind() == reflect.Uint8 {
			return value.Len()
		}
		total := 0
		for i := 0; i < value.Len() && total <= remaining; i++ {
			total += estimateValueBytes(value.Index(i), remaining-total, depth+1)
		}
		return total
	case reflect.Map:
		total := 0
		iter := value.MapRange()
		for iter.Next() && total <= remaining {
			total += estimateValueBytes(iter.Key(), remaining-total, depth+1)
			total += estimateValueBytes(iter.Value(), remaining-total, depth+1)
		}
		return total
	case reflect.Struct:
		total := 0
		for i := 0; i < value.NumField() && total <= remaining; i++ {
			total += estimateValueBytes(value.Field(i), remaining-total, depth+1)
		}
		return total
	case reflect.Bool, reflect.Int, reflect.Int8, reflect.Int16, reflect.Int32, reflect.Int64,
		reflect.Uint, reflect.Uint8, reflect.Uint16, reflect.Uint32, reflect.Uint64,
		reflect.Float32, reflect.Float64:
		return 8
	default:
		return 16
	}
}

func (c *connector) pruneRequestOperationsLocked(now time.Time, keepID string) {
	for id, operation := range c.requestOperations {
		if operation.done && now.Sub(operation.completedAt) >= requestReplayTTL {
			c.deleteRequestOperationLocked(id, operation)
		}
	}

	for c.requestReplayBytes > requestReplayMaxBytes || c.completedRequestCountLocked() > requestReplayMaxEntries {
		oldestID := ""
		var oldest *requestOperation
		for id, operation := range c.requestOperations {
			if id == keepID || !operation.done {
				continue
			}
			if oldest == nil || operation.completedAt.Before(oldest.completedAt) {
				oldestID = id
				oldest = operation
			}
		}
		if oldest == nil {
			break
		}
		c.deleteRequestOperationLocked(oldestID, oldest)
	}
}

func (c *connector) completedRequestCountLocked() int {
	count := 0
	for _, operation := range c.requestOperations {
		if operation.done {
			count++
		}
	}
	return count
}

func (c *connector) deleteRequestOperationLocked(id string, operation *requestOperation) {
	delete(c.requestOperations, id)
	c.requestReplayBytes -= operation.replyBytes
	if c.requestReplayBytes < 0 {
		c.requestReplayBytes = 0
	}
}
