package session

import (
	"sync"
	"time"
)

// Player is the queue of agent audio waiting to be played. A consumer (the
// speaker callback or the file writer) takes audio from it in real time.
// Marks sit at byte positions in the stream; a mark is played when the
// consumer has taken all audio queued before it. output.clear drops the
// queue, and the marks behind the dropped audio count as played, because
// nothing before them is left to play.
type Player struct {
	mu       sync.Mutex
	buf      []byte
	consumed int64
	queued   int64
	maxBytes int
	marks    []mark
	played   []string
	notify   chan struct{}
	lastTake time.Time
	dropped  int64
}

type mark struct {
	name string
	at   int64
}

// NewPlayer returns a player that holds at most maxBytes of queued audio.
// Audio beyond the bound is dropped and counted.
func NewPlayer(maxBytes int) *Player {
	return &Player{maxBytes: maxBytes, notify: make(chan struct{}, 1)}
}

// Push queues agent audio.
func (p *Player) Push(b []byte) {
	p.mu.Lock()
	defer p.mu.Unlock()
	room := p.maxBytes - len(p.buf)
	if room < len(b) {
		if room < 0 {
			room = 0
		}
		p.dropped += int64(len(b) - room)
		b = b[:room]
	}
	p.buf = append(p.buf, b...)
	p.queued += int64(len(b))
}

// Mark places a named mark after the audio queued so far.
func (p *Player) Mark(name string) {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.marks = append(p.marks, mark{name: name, at: p.queued})
	p.releaseLocked()
}

// Clear drops all queued audio.
func (p *Player) Clear() {
	p.mu.Lock()
	defer p.mu.Unlock()
	p.buf = nil
	p.queued = p.consumed
	for i := range p.marks {
		p.marks[i].at = p.consumed
	}
	p.releaseLocked()
}

// Take removes up to n bytes from the head of the queue. It is safe to call
// from an audio callback: it does not block on anything but the queue lock.
func (p *Player) Take(n int) []byte {
	p.mu.Lock()
	defer p.mu.Unlock()
	if n > len(p.buf) {
		n = len(p.buf)
	}
	out := make([]byte, n)
	copy(out, p.buf[:n])
	p.buf = p.buf[n:]
	p.consumed += int64(n)
	if n > 0 {
		p.lastTake = time.Now()
	}
	p.releaseLocked()
	return out
}

// Queued returns the number of bytes waiting to play.
func (p *Player) Queued() int {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.buf)
}

// Busy reports whether agent audio is queued or was taken within hold.
func (p *Player) Busy(hold time.Duration) bool {
	p.mu.Lock()
	defer p.mu.Unlock()
	return len(p.buf) > 0 || (!p.lastTake.IsZero() && time.Since(p.lastTake) < hold)
}

// Dropped returns the number of bytes dropped because the queue was full.
func (p *Player) Dropped() int64 {
	p.mu.Lock()
	defer p.mu.Unlock()
	return p.dropped
}

// Played returns and forgets the marks played since the last call.
func (p *Player) Played() []string {
	p.mu.Lock()
	defer p.mu.Unlock()
	out := p.played
	p.played = nil
	return out
}

// Notify is signalled when marks become played.
func (p *Player) Notify() <-chan struct{} { return p.notify }

func (p *Player) releaseLocked() {
	released := 0
	for released < len(p.marks) && p.marks[released].at <= p.consumed {
		p.played = append(p.played, p.marks[released].name)
		released++
	}
	if released == 0 {
		return
	}
	p.marks = p.marks[:copy(p.marks, p.marks[released:])]
	select {
	case p.notify <- struct{}{}:
	default:
	}
}
