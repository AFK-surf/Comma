package gateway

import (
	"bytes"
	"maps"
	"sync"

	"tailscale.com/ipn"
)

// stateStore is the node's ipn.StateStore. It holds the state in memory and
// makes every change durable through persist before WriteState returns: the
// owner on the Salix node writes the snapshot under its lease, so a node that
// has lost its lease cannot record new keys.
type stateStore struct {
	mu      sync.Mutex
	state   map[ipn.StateKey][]byte
	persist func(map[string][]byte) error
}

func newStateStore(initial map[string][]byte, persist func(map[string][]byte) error) *stateStore {
	state := make(map[ipn.StateKey][]byte, len(initial))
	for k, v := range initial {
		state[ipn.StateKey(k)] = bytes.Clone(v)
	}
	return &stateStore{state: state, persist: persist}
}

func (s *stateStore) ReadState(id ipn.StateKey) ([]byte, error) {
	s.mu.Lock()
	defer s.mu.Unlock()
	v, ok := s.state[id]
	if !ok {
		return nil, ipn.ErrStateNotExist
	}
	return bytes.Clone(v), nil
}

// WriteState holds the lock while it persists, so snapshots reach the owner
// in order.
func (s *stateStore) WriteState(id ipn.StateKey, bs []byte) error {
	s.mu.Lock()
	defer s.mu.Unlock()
	old, had := s.state[id]
	if (bs == nil && !had) || (had && bs != nil && bytes.Equal(old, bs)) {
		return nil
	}
	next := maps.Clone(s.state)
	if bs == nil {
		delete(next, id)
	} else {
		next[id] = bytes.Clone(bs)
	}
	snapshot := make(map[string][]byte, len(next))
	for k, v := range next {
		snapshot[string(k)] = v
	}
	if err := s.persist(snapshot); err != nil {
		return err
	}
	s.state = next
	return nil
}
