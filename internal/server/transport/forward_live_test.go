package transport

import (
	"context"
	"io"
	"net"
	"strconv"
	"testing"
	"time"

	"github.com/sirupsen/logrus"

	"github.com/backpack/backpack/internal/live"
)

// freePort returns a TCP port on 127.0.0.1 that is free right now.
func freePort(t *testing.T) string {
	t.Helper()
	l, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	defer l.Close()
	return strconv.Itoa(l.Addr().(*net.TCPAddr).Port)
}

// dialUntil dials addr until it connects or the deadline passes.
func dialUntil(t *testing.T, addr string) net.Conn {
	t.Helper()
	deadline := time.Now().Add(3 * time.Second)
	for {
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err == nil {
			return c
		}
		if time.Now().After(deadline) {
			t.Fatalf("could not connect to %s: %v", addr, err)
		}
		time.Sleep(20 * time.Millisecond)
	}
}

// refusedSoon reports whether addr stops accepting within the deadline.
func refusedSoon(addr string) bool {
	deadline := time.Now().Add(3 * time.Second)
	for time.Now().Before(deadline) {
		c, err := net.DialTimeout("tcp", addr, 200*time.Millisecond)
		if err != nil {
			return true
		}
		c.Close()
		time.Sleep(20 * time.Millisecond)
	}
	return false
}

func admitted(t *testing.T, q chan LocalTCPConn) LocalTCPConn {
	t.Helper()
	select {
	case c := <-q:
		return c
	case <-time.After(3 * time.Second):
		t.Fatal("no connection was admitted")
		return LocalTCPConn{}
	}
}

// stillOpen reports whether the user's side of an admitted connection is
// still connected: data written on the server side arrives.
func stillOpen(t *testing.T, user net.Conn, srv LocalTCPConn) bool {
	t.Helper()
	if _, err := srv.conn.Write([]byte("x")); err != nil {
		return false
	}
	_ = user.SetReadDeadline(time.Now().Add(2 * time.Second))
	b := make([]byte, 1)
	_, err := io.ReadFull(user, b)
	return err == nil && b[0] == 'x'
}

// TestLiveForwardsKeepAdmittedConnections drives one generation's forwarder
// through every live change and checks the zero-downtime promises: new
// mappings accept at once, a changed target applies to new users only, a
// removed port stops accepting while its users stay connected, and nothing
// that was admitted is ever closed by a mapping change.
func TestLiveForwardsKeepAdmittedConnections(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := logrus.New()
	log.SetLevel(logrus.WarnLevel)
	p1, p2 := freePort(t), freePort(t)
	a1, a2 := "127.0.0.1:"+p1, "127.0.0.1:"+p2
	ports := live.NewPorts([]string{a1 + "=7001"})
	var listeners listenerSet
	q := make(chan LocalTCPConn, 16)
	portForwarder{ctx: ctx, queue: q, limits: newLimiter(Limits{}), listeners: &listeners, log: log, live: ports}.run()

	u1 := dialUntil(t, a1)
	defer u1.Close()
	c1 := admitted(t, q)
	if c1.remoteAddr != "7001" {
		t.Fatalf("first user target = %q, want 7001", c1.remoteAddr)
	}

	// 1. add a mapping and point the existing one elsewhere, in one change
	ports.Set([]string{a1 + "=7002", a2 + "=7003"})
	u2 := dialUntil(t, a2)
	defer u2.Close()
	if c := admitted(t, q); c.remoteAddr != "7003" {
		t.Fatalf("new mapping target = %q, want 7003", c.remoteAddr)
	}
	u3 := dialUntil(t, a1)
	defer u3.Close()
	if c := admitted(t, q); c.remoteAddr != "7002" {
		t.Fatalf("retargeted mapping gave %q to a new user, want 7002", c.remoteAddr)
	}
	if !stillOpen(t, u1, c1) {
		t.Fatal("retargeting closed a connection that was already admitted")
	}

	// 2. remove the first port: it stops accepting, its user stays connected
	ports.Set([]string{a2 + "=7003"})
	if !refusedSoon(a1) {
		t.Fatal("a removed mapping still accepts new users")
	}
	if !stillOpen(t, u1, c1) {
		t.Fatal("removing the mapping closed a connection it had admitted (no graceful drain)")
	}

	// 3. moving a port: the new one accepts before the old one goes away
	p3 := freePort(t)
	a3 := "127.0.0.1:" + p3
	ports.Set([]string{a3 + "=7003"})
	u4 := dialUntil(t, a3)
	defer u4.Close()
	admitted(t, q)
	if !refusedSoon(a2) {
		t.Fatal("the old port of a moved mapping still accepts")
	}

	// 4. the generation's end still closes everything, as before
	cancel()
	listeners.wait(context.Background())
}

// TestUserPortHandover is the make-before-break handover of a user port from
// one tunnel to another: with user_port_reuse both bind the port at once, the
// old one goes away, and the port never stops accepting. Without it the
// second bind fails as it always did.
func TestUserPortHandover(t *testing.T) {
	log := logrus.New()
	log.SetLevel(logrus.ErrorLevel)
	addr := "127.0.0.1:" + freePort(t)

	oldCtx, oldStop := context.WithCancel(context.Background())
	var oldSet listenerSet
	oldQ := make(chan LocalTCPConn, 64)
	portForwarder{ctx: oldCtx, ports: []string{addr + "=1"}, queue: oldQ, limits: newLimiter(Limits{}), listeners: &oldSet, log: log, reusePort: true}.run()
	u := dialUntil(t, addr)
	defer u.Close()
	admitted(t, oldQ)

	newCtx, newStop := context.WithCancel(context.Background())
	defer newStop()
	var newSet listenerSet
	newQ := make(chan LocalTCPConn, 64)
	portForwarder{ctx: newCtx, ports: []string{addr + "=2"}, queue: newQ, limits: newLimiter(Limits{}), listeners: &newSet, log: log, reusePort: true}.run()
	time.Sleep(200 * time.Millisecond) // the new listener is up

	// the old tunnel goes; every dial from now on must reach the new one
	oldStop()
	oldSet.wait(context.Background())
	for i := 0; i < 20; i++ {
		c, err := net.DialTimeout("tcp", addr, time.Second)
		if err != nil {
			t.Fatalf("dial %d after the handover failed: %v", i, err)
		}
		if got := admitted(t, newQ); got.remoteAddr != "2" {
			t.Fatalf("dial %d reached target %q, want the new tunnel's 2", i, got.remoteAddr)
		}
		c.Close()
	}

	// without reuse a second bind of a held port still fails, as before
	holdCtx, holdStop := context.WithCancel(context.Background())
	defer holdStop()
	var holdSet listenerSet
	portForwarder{ctx: holdCtx, ports: []string{addr + "=3"}, queue: make(chan LocalTCPConn, 4), limits: newLimiter(Limits{}), listeners: &holdSet, log: log}.run()
	time.Sleep(200 * time.Millisecond)
	if _, err := listenTCP(addr, false); err == nil {
		t.Fatal("a plain bind of a port held with SO_REUSEPORT succeeded; the default must still refuse")
	}
}

// TestFixedForwarderUnchanged checks that without a live holder the forwarder
// binds its mappings exactly as it always did.
func TestFixedForwarderUnchanged(t *testing.T) {
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	log := logrus.New()
	log.SetLevel(logrus.WarnLevel)
	a := "127.0.0.1:" + freePort(t)
	var listeners listenerSet
	q := make(chan LocalTCPConn, 4)
	portForwarder{ctx: ctx, ports: []string{a + "=9100"}, queue: q, limits: newLimiter(Limits{}), listeners: &listeners, log: log}.run()
	u := dialUntil(t, a)
	defer u.Close()
	if c := admitted(t, q); c.remoteAddr != "9100" {
		t.Fatalf("target = %q, want 9100", c.remoteAddr)
	}
	cancel()
	listeners.wait(context.Background())
}
