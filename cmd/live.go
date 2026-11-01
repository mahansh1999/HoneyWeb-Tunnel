package cmd

import (
	"fmt"
	"reflect"
	"strings"
	"sync"

	"github.com/backpack/backpack/config"
	"github.com/backpack/backpack/internal/live"
)

// Zero-downtime reloads (HoneyWeb Tunnel).
//
// A changed configuration file used to end the running generation in every
// case, which cuts every connection of the tunnel for a moment. Two changes do
// not need that, and are now handed to the running tunnel instead:
//
//   - [server] ports: listeners open and close one by one; a removed port stops
//     taking new users while the ones it already has finish (internal/live,
//     internal/server/transport/forward.go);
//   - [client] connection_pool raised: the pool maintainer dials the extra
//     sessions; nothing is closed.
//
// Anything else in the same edit — or a smaller pool, a changed TLS identity,
// a server whose transports include the udp transport, or no tunnel running
// yet — takes the old path: the generation restarts with the new file. So the
// worst case is exactly the behaviour before this file existed.

// liveTargets are the holders of the generation that is running now, set by
// runEngine for as long as its server or client exists.
var liveTargets struct {
	sync.Mutex
	ports *live.Ports
	pool  *live.Pool
}

func setLiveTargets(ports *live.Ports, pool *live.Pool) {
	liveTargets.Lock()
	liveTargets.ports, liveTargets.pool = ports, pool
	liveTargets.Unlock()
}

// liveChange is what a reload would change, if it can be applied live.
type liveChange struct {
	ports    []string // new [server] ports, when they changed
	portsSet bool
	poolFrom int // [client] connection_pool raise, when it grew
	poolTo   int
}

// classifyLive reports whether the only differences between cur and next are
// ones the running tunnel can take, and which. It never mutates either config.
func classifyLive(cur, next *config.Config) (liveChange, bool) {
	var ch liveChange
	a, b := *cur, *next // shallow copies: only the copied fields are overwritten below
	if !reflect.DeepEqual(a.Server.Ports, b.Server.Ports) {
		if a.Server.BindAddr == "" {
			return ch, false // ports of a role that is not running
		}
		ch.ports, ch.portsSet = append([]string(nil), b.Server.Ports...), true
		b.Server.Ports = a.Server.Ports
	}
	if a.Client.ConnectionPool != b.Client.ConnectionPool {
		if a.Client.RemoteAddr == "" || b.Client.ConnectionPool < a.Client.ConnectionPool {
			return ch, false // a smaller pool needs the restart that closes sessions
		}
		ch.poolFrom, ch.poolTo = a.Client.ConnectionPool, b.Client.ConnectionPool
		b.Client.ConnectionPool = a.Client.ConnectionPool
	}
	if !ch.portsSet && ch.poolTo == 0 {
		return ch, false
	}
	return ch, reflect.DeepEqual(a, b)
}

// applyLive hands a live-applicable change to the running tunnel. It returns a
// description of what was applied, or ok=false when the change has to restart
// the generation instead (nothing has been changed in that case).
func applyLive(cur, next *config.Config) (string, bool) {
	ch, ok := classifyLive(cur, next)
	if !ok {
		return "", false
	}
	liveTargets.Lock()
	ports, pool := liveTargets.ports, liveTargets.pool
	liveTargets.Unlock()
	if (ch.portsSet && ports == nil) || (ch.poolTo > 0 && pool == nil) {
		return "", false
	}
	var done []string
	if ch.portsSet {
		ports.Set(ch.ports)
		done = append(done, fmt.Sprintf("ports [%s] -> [%s]", strings.Join(cur.Server.Ports, " "), strings.Join(ch.ports, " ")))
	}
	if ch.poolTo > 0 {
		pool.Raise(ch.poolTo)
		done = append(done, fmt.Sprintf("connection_pool %d -> %d", ch.poolFrom, ch.poolTo))
	}
	return strings.Join(done, ", "), true
}
