package cmd

import (
	"testing"

	"github.com/backpack/backpack/config"
	"github.com/backpack/backpack/internal/live"
)

func serverCfg(ports ...string) *config.Config {
	c := &config.Config{}
	c.Server.BindAddr = "0.0.0.0:9090"
	c.Server.Transport = config.WSSMUX
	c.Server.Token = "t"
	c.Server.Ports = ports
	return c
}

func clientCfg(pool int) *config.Config {
	c := &config.Config{}
	c.Client.RemoteAddr = "203.0.113.10:9090"
	c.Client.Transport = config.WSSMUX
	c.Client.Token = "t"
	c.Client.ConnectionPool = pool
	return c
}

func TestClassifyLive(t *testing.T) {
	other := serverCfg("540", "541")
	other.Server.Nodelay = !other.Server.Nodelay
	tls := serverCfg("540", "541")
	tls.Server.TLSCertFile = "/new.crt"
	cases := []struct {
		name      string
		cur, next *config.Config
		live      bool
	}{
		{"ports added", serverCfg("540"), serverCfg("540", "541"), true},
		{"target changed", serverCfg("540"), serverCfg("540=8388"), true},
		{"ports removed", serverCfg("540", "541"), serverCfg("540"), true},
		{"ports and another key", serverCfg("540"), other, false},
		{"ports and the certificate", serverCfg("540"), tls, false},
		{"pool raised", clientCfg(512), clientCfg(640), true},
		{"pool lowered restarts", clientCfg(640), clientCfg(512), false},
		{"nothing live changed", serverCfg("540"), serverCfg("540"), false},
	}
	for _, c := range cases {
		cur := *c.cur
		_, got := classifyLive(c.cur, c.next)
		if got != c.live {
			t.Errorf("%s: live = %v, want %v", c.name, got, c.live)
		}
		if c.cur.Server.BindAddr != cur.Server.BindAddr || len(c.cur.Server.Ports) != len(cur.Server.Ports) {
			t.Errorf("%s: classifyLive modified the current config", c.name)
		}
	}
}

func TestApplyLiveNeedsARunningTunnel(t *testing.T) {
	setLiveTargets(nil, nil)
	if _, ok := applyLive(serverCfg("540"), serverCfg("540", "541")); ok {
		t.Fatal("applied live with no running server: must fall back to a restart")
	}
	ports := live.NewPorts([]string{"540"})
	setLiveTargets(ports, nil)
	defer setLiveTargets(nil, nil)
	if what, ok := applyLive(serverCfg("540"), serverCfg("540", "541")); !ok || what == "" {
		t.Fatalf("live apply refused: %q", what)
	}
	if got := ports.Get(); len(got) != 2 || got[1] != "541" {
		t.Fatalf("running ports = %v", got)
	}
	if _, ok := applyLive(clientCfg(512), clientCfg(640)); ok {
		t.Fatal("a pool raise was applied with no running client")
	}
	pool := live.NewPool(512)
	setLiveTargets(nil, pool)
	if _, ok := applyLive(clientCfg(512), clientCfg(640)); !ok || pool.Get(0) != 640 {
		t.Fatalf("pool raise not applied: %d", pool.Get(0))
	}
}
