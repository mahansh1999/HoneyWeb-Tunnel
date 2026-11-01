package transport

import (
	"context"
	"net"
	"strings"
	"sync"
	"sync/atomic"
	"time"

	"github.com/sirupsen/logrus"

	"github.com/backpack/backpack/internal/live"
	"github.com/backpack/backpack/internal/utils/network"
)

// portForwarder is the user-facing half of a stream transport on the Iran
// side: it binds every forwarded port — TCP, and UDP too when the tunnel
// forwards it — admits each connection under the tunnel's limits into the
// generation's local queue, tells the transport a connection is waiting, and
// gives back whatever is still queued when the generation ends.
//
// All six stream transports had their own copy of this — mapping parser,
// listener, accept loop — differing only in the socket options they set on a
// user's connection and in what they do once one is queued. Those two
// differences are the adapters (tune and queued); everything else, including
// the fixes that each copy needed separately (limits released on every path,
// the queue drained when the generation ends), is here once.
type portForwarder struct {
	ctx       context.Context
	ports     []string
	acceptUDP bool
	queue     chan LocalTCPConn
	limits    *limiter
	listeners *listenerSet
	log       *logrus.Logger

	// tune applies the transport's socket options to an accepted user
	// connection. Optional.
	tune func(*net.TCPConn)
	// queued runs once a connection — a TCP client or a new UDP flow — is
	// waiting in queue: the transport asks its client for a tunnel connection
	// or a stream to carry it. Optional.
	queued func()

	// live, when set, makes the mappings changeable while the generation runs
	// (internal/live): the forwarder starts from live.Get() instead of ports
	// and follows every later Set. Optional; nil keeps the fixed mappings.
	live *live.Ports

	// reusePort binds the user ports with SO_REUSEPORT (config user_port_reuse),
	// so another tunnel taking over the same ports can bind them first.
	reusePort bool
}

// run binds every mapping and returns; the listeners live until ctx ends.
func (f portForwarder) run() {
	go drainOnEnd(f.ctx, f.queue, f.limits)
	if f.live == nil {
		eachForward(f.ports, f.log, func(localAddr, target string) {
			go f.listen(f.ctx, localAddr, fixedTarget(target))
		})
		return
	}
	set := &liveForwards{f: f, active: map[string]*liveListener{}}
	set.reconcile(f.live.Get())
	unsubscribe := f.live.Subscribe(set.reconcile)
	context.AfterFunc(f.ctx, unsubscribe)
}

// fixedTarget is the target of a mapping that cannot change.
func fixedTarget(t string) func() string { return func() string { return t } }

// liveListener is one bound address of a live forwarder.
type liveListener struct {
	stop   context.CancelFunc
	target atomic.Pointer[string]
}

// liveForwards keeps a generation's listeners equal to the live mappings.
type liveForwards struct {
	f      portForwarder
	mu     sync.Mutex
	active map[string]*liveListener
}

// reconcile moves the listeners to ports without touching a connection that is
// already admitted: those belong to the generation (limits.wrap(f.ctx, ...)),
// not to the listener that accepted them, so a closed listener only stops new
// users while the ones it let in finish their sessions (graceful draining).
//
// Order matters for a port that moves: new addresses are bound first, then
// targets are swapped, and listeners that are no longer wanted close last, so
// there is no moment in which neither the old nor the new port accepts.
func (s *liveForwards) reconcile(ports []string) {
	s.mu.Lock()
	defer s.mu.Unlock()
	if s.f.ctx.Err() != nil {
		return
	}
	want := map[string]string{}
	var order []string
	eachForward(ports, s.f.log, func(localAddr, target string) {
		if _, dup := want[localAddr]; !dup {
			order = append(order, localAddr)
		}
		want[localAddr] = target
	})
	for _, addr := range order {
		target := want[addr]
		l, ok := s.active[addr]
		if !ok {
			ctx, stop := context.WithCancel(s.f.ctx)
			l = &liveListener{stop: stop}
			l.target.Store(&target)
			s.active[addr] = l
			go s.f.listen(ctx, addr, func() string { return *l.target.Load() })
			s.f.log.Infof("live: now listening on %s -> %s (no restart)", addr, target)
			continue
		}
		if old := *l.target.Load(); old != target {
			l.target.Store(&target)
			s.f.log.Infof("live: %s now forwards new connections to %s (was %s); open connections keep theirs", addr, target, old)
		}
	}
	for addr, l := range s.active {
		if _, keep := want[addr]; keep {
			continue
		}
		l.stop()
		delete(s.active, addr)
		s.f.log.Infof("live: stopped listening on %s; its open connections continue until they end", addr)
	}
}

// eachForward expands the port mappings and calls bind for every port they
// name, with its target. A mapping that cannot be read is one mapping, not a
// reason to end the process — under a unit that restarts every three seconds
// one typo used to become a crash loop — so it is reported and skipped, and
// the tunnel's other ports are unaffected.
func eachForward(ports []string, log *logrus.Logger, bind func(localAddr, target string)) {
	for _, portMapping := range ports {
		parts := strings.Split(portMapping, "=")
		if len(parts) > 2 {
			log.Errorf("ignoring the port mapping %q: it has more than one '='", portMapping)
			continue
		}
		// The listen side is an optional bind address and either one port or
		// a range; see expandListenSpec.
		listens, err := expandListenSpec(parts[0])
		if err != nil {
			log.Errorf("ignoring the port mapping %q: %v", portMapping, err)
			continue
		}

		var remoteAddr string
		if len(parts) == 2 {
			remoteAddr = strings.TrimSpace(parts[1])
		}

		for _, l := range listens {
			// With no target, each port forwards to the same port on the far side.
			target := remoteAddr
			if target == "" {
				target = l.port
			}
			bind(l.addr, target)
			if len(listens) > 1 {
				time.Sleep(1 * time.Millisecond) // for wide port ranges
			}
		}
	}
}

// listen serves one forwarded port until ctx ends: the generation's context,
// or for a live mapping a child of it that ends when the mapping is removed.
// target is read for every new connection, so a live mapping can be pointed
// elsewhere without rebinding.
func (f portForwarder) listen(ctx context.Context, localAddr string, target func() string) {
	// Counted so a restart can wait for the port to be free again.
	f.listeners.hold()
	defer f.listeners.release()

	listener, err := listenTCP(localAddr, f.reusePort)
	if err != nil {
		// Not fatal: one port being taken must not stop the others.
		f.log.Error(bindFailure("forwarded port", localAddr, err))
		return
	}
	defer listener.Close()

	f.log.Infof("listener started successfully, listening on address: %s", listener.Addr().String())

	go f.accept(ctx, listener, target)

	// The same port number, over UDP, when the tunnel forwards UDP. Its flows
	// travel through the tunnel exactly like TCP connections do. A new flow
	// takes the target current at its start (marked as UDP, as newUDPForwarder
	// does for the fixed target); flows already running keep theirs.
	if f.acceptUDP {
		go startUDPForwardReuse(ctx, f.log, localAddr, target(), func(c net.Conn, _ string) bool { return f.admitUDP(c, network.MarkUDP(target())) }, f.reusePort)
	}

	<-ctx.Done()
}

// accept admits the users of one forwarded port into the queue.
func (f portForwarder) accept(ctx context.Context, listener net.Listener, target func() string) {
	var backoff acceptBackoff
	for {
		select {
		case <-ctx.Done():
			return
		default:
		}
		conn, err := listener.Accept()
		if err != nil {
			f.log.Debugf("failed to accept connection on %s: %v", listener.Addr(), err)
			// A closed listener ends the loop; anything else is retried with
			// a pause, so a persistent error does not spin a core.
			if !backoff.Fail(ctx) {
				return
			}
			continue
		}
		backoff.OK()

		tcpConn, ok := conn.(*net.TCPConn)
		if !ok {
			f.log.Warnf("discarded non-TCP connection from %s", conn.RemoteAddr().String())
			conn.Close()
			continue
		}
		if f.tune != nil {
			f.tune(tcpConn)
		}

		// The connection cap is enforced here, where users arrive: refusing
		// before queueing costs nothing downstream.
		if !f.limits.acquire() {
			f.log.Warnf("connection limit reached, refusing %s", conn.RemoteAddr())
			conn.Close()
			continue
		}
		wrapped := f.limits.wrap(f.ctx, conn)

		select {
		case f.queue <- LocalTCPConn{conn: wrapped, remoteAddr: target(), timeCreated: time.Now().UnixMilli()}:
			f.log.Debugf("forwarded port: accepted a client from %s", tcpConn.RemoteAddr().String())
			if f.queued != nil {
				f.queued()
			}
		default:
			// The queue is full: the tunnel is not keeping up, and holding the
			// connection open longer only delays the user's retry.
			f.log.Warnf("forwarded port %s: the queue is full, dropping a client from %s",
				listener.Addr().String(), tcpConn.RemoteAddr().String())
			f.limits.release()
			conn.Close()
		}
	}
}

// admitUDP admits a new UDP flow exactly as accept admits a TCP connection:
// the same cap, the same queue, the same request for a way through.
func (f portForwarder) admitUDP(conn net.Conn, target string) bool {
	if !f.limits.acquire() {
		return false
	}
	select {
	case f.queue <- LocalTCPConn{conn: f.limits.wrap(f.ctx, conn), remoteAddr: target, timeCreated: time.Now().UnixMilli()}:
		if f.queued != nil {
			f.queued()
		}
		return true
	default:
		f.limits.release()
		return false
	}
}

// requestAlways is the queued adapter of the transports that carry one user
// per tunnel connection: every waiting user asks the client for one more.
func requestAlways(reqNewConn chan struct{}, log *logrus.Logger) func() {
	return func() {
		select {
		case reqNewConn <- struct{}{}:
		default:
			// Already enough requests outstanding to cover the queue.
			log.Warn("channel is full, cannot request a new connection")
		}
	}
}

// nodelayTune turns Nagle's algorithm back on for a user's connection when the
// tunnel is configured without nodelay; accepted sockets have it off.
func nodelayTune(nodelay bool, log *logrus.Logger) func(*net.TCPConn) {
	return func(c *net.TCPConn) {
		if nodelay {
			return
		}
		if err := c.SetNoDelay(false); err != nil {
			log.Warnf("failed to set TCP_NODELAY for %s: %v", c.RemoteAddr().String(), err)
		}
	}
}

// muxRequest is the queued adapter of the mux transports: a waiting user is
// one more stream, and a new session is asked for only once the live ones are
// carrying as many streams as they may.
func muxRequest(streams, sessions *int32, muxCon int, reqNewConn chan struct{}, log *logrus.Logger) func() {
	return func() {
		n := atomic.AddInt32(streams, 1)
		if n < atomic.LoadInt32(sessions)*int32(muxCon) {
			return
		}
		log.Tracef("stream counter: %v, session counter: %v", n, atomic.LoadInt32(sessions))
		select {
		case reqNewConn <- struct{}{}:
		default:
			log.Warn("failed to request new connection. channel is full")
		}
	}
}

func muxRequestForGeneration(ctx context.Context, mu *sync.Mutex, streams, sessions *int32, muxCon int, reqNewConn chan struct{}, log *logrus.Logger) func() {
	ask := muxRequest(streams, sessions, muxCon, reqNewConn, log)
	return func() {
		mu.Lock()
		defer mu.Unlock()
		if ctx.Err() == nil {
			ask()
		}
	}
}

// alwaysNodelay turns Nagle's algorithm off on a user's connection, for the
// transports that do so whatever the configuration says.
func alwaysNodelay(log *logrus.Logger) func(*net.TCPConn) {
	return func(c *net.TCPConn) {
		if err := c.SetNoDelay(true); err != nil {
			log.Warnf("failed to set TCP_NODELAY for %s: %v", c.RemoteAddr().String(), err)
		}
	}
}

// wsTune is the websocket transports' socket options for a user's connection.
func wsTune(c *net.TCPConn, nodelay bool, keepAlive time.Duration, log *logrus.Logger) {
	nodelayTune(nodelay, log)(c)
	if err := c.SetKeepAlive(true); err != nil {
		log.Warnf("failed to enable TCP keep-alive for %s: %v", c.RemoteAddr().String(), err)
	}
	if err := c.SetKeepAlivePeriod(keepAlive); err != nil {
		log.Warnf("failed to set TCP keep-alive period for %s: %v", c.RemoteAddr().String(), err)
	}
}
