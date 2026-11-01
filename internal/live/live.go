// Package live carries the configuration changes a running tunnel takes
// without restarting its generation (HoneyWeb Tunnel, zero-downtime management).
//
// Today a reload ends the generation and starts a new one, which cuts every
// connection of that tunnel for a moment. Two changes do not need that:
//
//   - the server's port mappings: listeners can be opened and closed one by one,
//     and a user's connection is owned by the generation, not by the listener
//     that accepted it, so closing a listener lets its connections finish;
//   - a larger client connection pool: the pool maintainer only has to aim
//     higher, and no session is closed to get there.
//
// cmd decides whether a changed file is only such a change (everything else
// still restarts the generation, exactly as before) and hands the new value to
// the running tunnel through these holders. The transports read them. A nil
// holder means "not live": the transport uses its configuration as it always
// did, so nothing changes for code or tests that do not set one.
//
// The package imports only the standard library.
package live

import (
	"sync"
	"sync/atomic"
)

// Ports is the live list of a server's port mappings.
type Ports struct {
	mu    sync.Mutex
	ports []string
	subs  map[int]func([]string)
	next  int
}

// NewPorts starts the holder with the mappings the tunnel was started with.
func NewPorts(ports []string) *Ports {
	return &Ports{ports: clone(ports), subs: map[int]func([]string){}}
}

// Get returns the current mappings (a copy).
func (p *Ports) Get() []string {
	if p == nil {
		return nil
	}
	p.mu.Lock()
	defer p.mu.Unlock()
	return clone(p.ports)
}

// Set stores new mappings and tells every subscriber, in subscription order of
// arrival, holding no lock while they run. It reports how many listener sets
// were told: zero means no generation is serving right now, and the mappings
// take effect when the next one starts.
func (p *Ports) Set(ports []string) int {
	p.mu.Lock()
	p.ports = clone(ports)
	fns := make([]func([]string), 0, len(p.subs))
	for i := 0; i < p.next; i++ {
		if fn, ok := p.subs[i]; ok {
			fns = append(fns, fn)
		}
	}
	p.mu.Unlock()
	for _, fn := range fns {
		fn(clone(ports))
	}
	return len(fns)
}

// Subscribe registers fn to be called with every new list. The returned
// function unsubscribes; calling it twice is harmless.
func (p *Ports) Subscribe(fn func([]string)) (unsubscribe func()) {
	p.mu.Lock()
	id := p.next
	p.next++
	p.subs[id] = fn
	p.mu.Unlock()
	var once sync.Once
	return func() {
		once.Do(func() {
			p.mu.Lock()
			delete(p.subs, id)
			p.mu.Unlock()
		})
	}
}

// Pool is the live connection-pool size of a client.
type Pool struct {
	v atomic.Int64
}

// NewPool starts the holder at the configured size.
func NewPool(size int) *Pool {
	p := &Pool{}
	p.v.Store(int64(size))
	return p
}

// Get returns the current size; a nil holder returns fallback.
func (p *Pool) Get(fallback int) int {
	if p == nil {
		return fallback
	}
	return int(p.v.Load())
}

// Raise sets a larger size. It never lowers the pool (a smaller pool needs the
// generation restart that closes sessions) and reports whether it changed.
func (p *Pool) Raise(size int) bool {
	for {
		cur := p.v.Load()
		if int64(size) <= cur {
			return false
		}
		if p.v.CompareAndSwap(cur, int64(size)) {
			return true
		}
	}
}

func clone(s []string) []string {
	if s == nil {
		return nil
	}
	out := make([]string, len(s))
	copy(out, s)
	return out
}
