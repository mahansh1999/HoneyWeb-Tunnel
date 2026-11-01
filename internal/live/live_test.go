package live

import (
	"reflect"
	"sync"
	"testing"
)

func TestPortsSetNotifiesSubscribersAndCopies(t *testing.T) {
	p := NewPorts([]string{"540"})
	var got [][]string
	var mu sync.Mutex
	stop := p.Subscribe(func(ports []string) { mu.Lock(); got = append(got, ports); mu.Unlock() })
	in := []string{"540", "541=540"}
	if n := p.Set(in); n != 1 {
		t.Fatalf("Set told %d subscribers, want 1", n)
	}
	in[0] = "changed" // the holder must not share the caller's slice
	if !reflect.DeepEqual(p.Get(), []string{"540", "541=540"}) {
		t.Fatalf("Get = %v", p.Get())
	}
	stop()
	stop() // twice is harmless
	if n := p.Set([]string{"9"}); n != 0 {
		t.Fatalf("an unsubscribed listener was told (%d)", n)
	}
	if len(got) != 1 || !reflect.DeepEqual(got[0], []string{"540", "541=540"}) {
		t.Fatalf("subscriber saw %v", got)
	}
}

func TestPortsNilGet(t *testing.T) {
	var p *Ports
	if p.Get() != nil {
		t.Fatal("nil holder must return nil")
	}
}

func TestPoolRaiseNeverLowers(t *testing.T) {
	p := NewPool(512)
	if p.Raise(384) || p.Get(0) != 512 {
		t.Fatalf("a smaller value changed the pool: %d", p.Get(0))
	}
	if !p.Raise(640) || p.Get(0) != 640 {
		t.Fatalf("raise to 640 failed: %d", p.Get(0))
	}
	if p.Raise(640) {
		t.Fatal("raising to the same value reported a change")
	}
	var nilPool *Pool
	if nilPool.Get(77) != 77 {
		t.Fatal("nil pool must return the fallback")
	}
}

func TestPoolRaiseConcurrent(t *testing.T) {
	p := NewPool(8)
	var wg sync.WaitGroup
	for i := 9; i <= 200; i++ {
		wg.Add(1)
		go func(n int) { defer wg.Done(); p.Raise(n) }(i)
	}
	wg.Wait()
	if p.Get(0) != 200 {
		t.Fatalf("concurrent raises ended at %d, want 200", p.Get(0))
	}
}
