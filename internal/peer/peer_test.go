package peer

import (
	"context"
	"net"
	"os"
	"path/filepath"
	"strings"
	"sync/atomic"
	"testing"
	"time"
)

const tok = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"

// etcWith makes a config directory holding tunnel NAME with token t.
func etcWith(t *testing.T, name, token string) string {
	t.Helper()
	d := t.TempDir()
	cfg := "[server]\nbind_addr = \"0.0.0.0:9090\"\ntoken = \"" + token + "\"\n"
	if err := os.WriteFile(filepath.Join(d, name+".toml"), []byte(cfg), 0o600); err != nil {
		t.Fatal(err)
	}
	return d
}

// fake records what would have run instead of running manage.sh.
func fake(prefix string) func(context.Context, []string) (int, string) {
	return func(_ context.Context, args []string) (int, string) { return 0, prefix + strings.Join(args, " ") }
}

func TestSignatureClockAndReplay(t *testing.T) {
	a := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("ran ")}
	r := &Request{Op: "run", Args: []string{"list"}}
	Sign(tok, r)
	if resp := a.Handle(context.Background(), r); !resp.OK || resp.Out != "ran list" {
		t.Fatalf("a correctly signed request was refused: %+v", resp)
	}
	if resp := a.Handle(context.Background(), r); resp.OK || !strings.Contains(resp.Err, "replayed") {
		t.Fatalf("a replay was accepted: %+v", resp)
	}
	r2 := &Request{Op: "run", Args: []string{"list"}}
	Sign(tok, r2)
	r2.Args = []string{"remove", "wssmux", "--confirm", "wssmux"}
	if resp := a.Handle(context.Background(), r2); resp.OK || !strings.Contains(resp.Err, "signature") {
		t.Fatalf("tampered arguments were accepted: %+v", resp)
	}
	r3 := &Request{Op: "run", Args: []string{"list"}}
	Sign("another-token", r3)
	if resp := a.Handle(context.Background(), r3); resp.OK {
		t.Fatalf("a request for an unknown tunnel was accepted: %+v", resp)
	}
	old := &Agent{Etc: a.Etc, Exec: fake(""), Now: func() time.Time { return time.Now().Add(10 * time.Minute) }}
	r4 := &Request{Op: "run", Args: []string{"list"}}
	Sign(tok, r4)
	if resp := old.Handle(context.Background(), r4); resp.OK || !strings.Contains(resp.Err, "clock") {
		t.Fatalf("a request 10 minutes old was accepted: %+v", resp)
	}
}

func TestOnlyWhitelistedCommands(t *testing.T) {
	a := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("")}
	for _, args := range [][]string{{"rm", "-rf", "/"}, {"ports", "wssmux;id"}, {"ports", "a b"}, {}, {"pool", "wssmux", "1024", "--test-fail-health"}} {
		r := &Request{Op: "run", Args: args}
		Sign(tok, r)
		if resp := a.Handle(context.Background(), r); resp.OK {
			t.Errorf("%q was run", args)
		}
	}
}

// serve starts an agent on a random loopback port.
func serve(t *testing.T, a *Agent) (string, context.CancelFunc) {
	t.Helper()
	ln, err := net.Listen("tcp", "127.0.0.1:0")
	if err != nil {
		t.Fatal(err)
	}
	ctx, cancel := context.WithCancel(context.Background())
	go a.Serve(ctx, ln)
	return ln.Addr().String(), cancel
}

func TestIranRunsAbroadDirectly(t *testing.T) {
	foreign := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("foreign ran ")}
	addr, stop := serve(t, foreign)
	defer stop()
	iranEtc := etcWith(t, "wssmux", tok)
	rc, out, err := RunRemote(context.Background(), iranEtc, "wssmux", addr, []string{"pool", "wssmux", "1152"})
	if err != nil || rc != 0 || out != "foreign ran pool wssmux 1152" {
		t.Fatalf("rc=%d out=%q err=%v", rc, out, err)
	}
}

// TestForeignRunsInIranThroughTheQueue is the reverse direction: the foreign
// side queues, the Iran agent polls through the tunnel, runs, and answers.
func TestForeignRunsInIranThroughTheQueue(t *testing.T) {
	foreign := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("foreign ")}
	faddr, stop := serve(t, foreign)
	defer stop()
	iran := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("iran ran ")}
	ctx, cancel := context.WithCancel(context.Background())
	defer cancel()
	go iran.Poll(ctx, "wssmux", faddr) // through the management mapping in real life

	rc, out, err := RunViaQueue(context.Background(), foreign.Etc, "wssmux", faddr, []string{"ports", "wssmux", "add", "541=540"})
	if err != nil || rc != 0 || out != "iran ran ports wssmux add 541=540" {
		t.Fatalf("rc=%d out=%q err=%v", rc, out, err)
	}
}

// TestIranRefusesATamperedQueuedRequest: the queue cannot be used to smuggle a
// command the foreign caller did not sign.
func TestIranRefusesATamperedQueuedRequest(t *testing.T) {
	foreign := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: fake("")}
	faddr, stop := serve(t, foreign)
	defer stop()
	inner := &Request{Op: "run", Args: []string{"list"}}
	Sign(tok, inner)
	inner.Args = []string{"remove", "wssmux", "--confirm", "wssmux"} // changed after signing
	enq := &Request{Op: "enqueue", Inner: inner}
	Sign(tok, enq)
	resp, err := Call(context.Background(), faddr, enq)
	if err != nil || !resp.OK {
		t.Fatalf("enqueue: %+v %v", resp, err)
	}
	var ran atomic.Bool
	iran := &Agent{Etc: etcWith(t, "wssmux", tok), Exec: func(context.Context, []string) (int, string) { ran.Store(true); return 0, "" }}
	ctx, cancel := context.WithTimeout(context.Background(), 5*time.Second)
	defer cancel()
	go iran.Poll(ctx, "wssmux", faddr)
	for i := 0; i < 40; i++ {
		w := &Request{Op: "wait", ID: resp.ID}
		Sign(tok, w)
		r, _ := Call(context.Background(), faddr, w)
		if r.Done {
			if r.RC == 0 || !strings.Contains(r.Out, "bad signature") || ran.Load() {
				t.Fatalf("a tampered request was run or not refused: rc=%d out=%q ran=%v", r.RC, r.Out, ran.Load())
			}
			return
		}
		time.Sleep(200 * time.Millisecond)
	}
	t.Fatal("no answer for the tampered request")
}

func TestServeIsLoopbackOnly(t *testing.T) {
	if rc := Main([]string{"serve", "--listen", "0.0.0.0:59111"}, os.Stdout, os.Stderr); rc != 2 {
		t.Fatalf("serve on 0.0.0.0 returned %d, want a refusal (2)", rc)
	}
}
