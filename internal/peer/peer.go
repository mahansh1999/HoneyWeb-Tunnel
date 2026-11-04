// Package peer is HoneyWeb Tunnel's two-sided management channel: one agent per
// server, listening on loopback only, reached by the other server through the
// tunnel itself (a management mapping on the Iran side, 127.0.0.1:P on Iran ->
// 127.0.0.1:59111 abroad). No port is opened to the internet.
//
// Every request is signed with HMAC-SHA256 under the token of the tunnel it is
// about, carries a timestamp and a nonce, and is refused if either is off. So
// only a holder of that tunnel's token — root on one of its two servers — can
// ask anything, and a captured request cannot be replayed.
//
// The tunnel is reverse: only Iran opens streams. Iran reaches the foreign agent
// directly. The foreign side reaches Iran by queueing a request in its own agent;
// the Iran agent polls that queue through the tunnel, runs the request and posts
// the result back. Either side can therefore manage both.
//
// What an agent runs is honeyweb/manage.sh with a whitelisted command — the same
// transactions (backup, check, impact, health, rollback) as a local call.
//
// The package imports only the standard library.
package peer

import (
	"bufio"
	"context"
	"crypto/hmac"
	"crypto/rand"
	"crypto/sha256"
	"encoding/hex"
	"encoding/json"
	"errors"
	"fmt"
	"net"
	"os"
	"os/exec"
	"path/filepath"
	"regexp"
	"strconv"
	"strings"
	"sync"
	"time"
)

// DefaultAgentAddr is where every agent listens.
const DefaultAgentAddr = "127.0.0.1:59111"

const (
	maxRequest  = 16 << 10
	maxOutput   = 256 << 10
	clockSkew   = 120 * time.Second
	runTimeout  = 180 * time.Second
	waitTimeout = 120 * time.Second
	pollEvery   = 2 * time.Second
)

// Request is one signed call.
type Request struct {
	V     int      `json:"v"`
	TID   string   `json:"tid"` // tunnel id: first 12 hex of sha256(token), as manage.sh shows it
	Op    string   `json:"op"`  // run, enqueue, poll, result, wait
	Args  []string `json:"args,omitempty"`
	TS    int64    `json:"ts"`
	Nonce string   `json:"nonce"`
	ID    string   `json:"id,omitempty"` // request id of a queued call (enqueue/poll/result/wait)
	Inner *Request `json:"inner,omitempty"`
	RC    int      `json:"rc,omitempty"`  // result: exit code
	Out   string   `json:"out,omitempty"` // result: output
	MAC   string   `json:"mac"`
}

// Response is the agent's answer.
type Response struct {
	OK    bool     `json:"ok"`
	Err   string   `json:"err,omitempty"`
	RC    int      `json:"rc,omitempty"`
	Out   string   `json:"out,omitempty"`
	ID    string   `json:"id,omitempty"`
	Inner *Request `json:"inner,omitempty"`
	Done  bool     `json:"done,omitempty"`
}

// TunnelID is the id manage.sh shows for a token.
func TunnelID(token string) string {
	h := sha256.Sum256([]byte(token))
	return hex.EncodeToString(h[:])[:12]
}

func macOf(token string, r *Request) string {
	m := hmac.New(sha256.New, []byte(token))
	inner := ""
	if r.Inner != nil {
		inner = r.Inner.MAC
	}
	fmt.Fprintf(m, "hwt-peer-v1\n%s\n%s\n%s\n%d\n%s\n%s\n%d\n%s\n%s", r.TID, r.Op, strings.Join(r.Args, "\x1f"),
		r.TS, r.Nonce, r.ID, r.RC, r.Out, inner)
	return hex.EncodeToString(m.Sum(nil))
}

// Sign fills ts, nonce and mac.
func Sign(token string, r *Request) {
	r.V = 1
	r.TID = TunnelID(token)
	r.TS = time.Now().Unix()
	b := make([]byte, 12)
	_, _ = rand.Read(b)
	r.Nonce = hex.EncodeToString(b)
	r.MAC = macOf(token, r)
}

// --- what may be run --------------------------------------------------------------------------------------------

var (
	allowedCmd = map[string]bool{"list": true, "show": true, "ports": true, "pool": true, "profile": true,
		"restart": true, "backups": true, "restore": true, "remove": true, "version": true,
		// make-before-break migration (manage.sh migrate): the client side of the new tunnel, and starting or
		// following a migration from the foreign side (it runs on Iran in the background)
		"clone-client": true, "migrate": true, "migrate-status": true, "migrate-abort": true, "migrate-resume": true, "migrate-list": true,
		// addresses: the scheduled tunnel-port switch of the other side, and a planned IP change made from either side
		"tunnel-port": true, "set-remote": true, "set-allow": true}
	argRE = regexp.MustCompile(`^[A-Za-z0-9._:=,/-]{1,200}$`)
)

// checkCommand refuses anything but a whitelisted manage.sh command with plain arguments.
func checkCommand(args []string) error {
	if len(args) == 0 || !allowedCmd[args[0]] {
		return errors.New("command not allowed")
	}
	if len(args) > 12 {
		return errors.New("too many arguments")
	}
	for _, a := range args {
		if !argRE.MatchString(a) || strings.HasPrefix(a, "--test") {
			return fmt.Errorf("argument not allowed: %q", a)
		}
	}
	return nil
}

// --- tokens -----------------------------------------------------------------------------------------------------

var tokenLine = regexp.MustCompile(`(?m)^\s*token\s*=\s*"([^"]+)"`)

// Tokens maps tunnel id -> token for every tunnel config in etc.
func Tokens(etc string) map[string]string {
	out := map[string]string{}
	files, _ := filepath.Glob(filepath.Join(etc, "*.toml"))
	for _, f := range files {
		b, err := os.ReadFile(f)
		if err != nil {
			continue
		}
		if m := tokenLine.FindSubmatch(b); m != nil {
			out[TunnelID(string(m[1]))] = string(m[1])
		}
	}
	return out
}

// TokenOf returns the token of tunnel NAME in etc.
func TokenOf(etc, name string) (string, error) {
	b, err := os.ReadFile(filepath.Join(etc, name+".toml"))
	if err != nil {
		return "", err
	}
	m := tokenLine.FindSubmatch(b)
	if m == nil {
		return "", errors.New("no token in " + name + ".toml")
	}
	return string(m[1]), nil
}

// queued is a request one side left for the other, untouched (its signature
// covers every field), with the id its result will be posted under.
type queued struct {
	id  string
	req *Request
}

// --- the agent --------------------------------------------------------------------------------------------------

// Agent serves one server's side of the channel.
type Agent struct {
	Etc    string                                                 // /opt/hwtunnel/etc
	Manage string                                                 // path to manage.sh
	Exec   func(ctx context.Context, args []string) (int, string) // replaced in tests
	Now    func() time.Time

	mu      sync.Mutex
	seen    map[string]time.Time // nonce -> expiry
	queue   map[string][]queued
	results map[string]*Request
	running sync.Mutex // one manage.sh at a time
}

func (a *Agent) init() {
	a.mu.Lock()
	defer a.mu.Unlock()
	if a.seen == nil {
		a.seen, a.queue, a.results = map[string]time.Time{}, map[string][]queued{}, map[string]*Request{}
	}
	if a.Now == nil {
		a.Now = time.Now
	}
	if a.Exec == nil {
		a.Exec = a.runManage
	}
}

// verify checks the signature, the clock and the nonce, and returns the token.
func (a *Agent) verify(r *Request) (string, error) {
	if r == nil || r.V != 1 {
		return "", errors.New("bad request")
	}
	token, ok := Tokens(a.Etc)[r.TID]
	if !ok {
		return "", errors.New("unknown tunnel")
	}
	if !hmac.Equal([]byte(macOf(token, r)), []byte(r.MAC)) {
		return "", errors.New("bad signature")
	}
	now := a.Now()
	if d := now.Sub(time.Unix(r.TS, 0)); d > clockSkew || d < -clockSkew {
		return "", errors.New("clock skew too large")
	}
	a.mu.Lock()
	defer a.mu.Unlock()
	for n, exp := range a.seen {
		if now.After(exp) {
			delete(a.seen, n)
		}
	}
	if _, dup := a.seen[r.Nonce]; dup || len(r.Nonce) < 16 {
		return "", errors.New("replayed request")
	}
	a.seen[r.Nonce] = now.Add(2 * clockSkew)
	return token, nil
}

// Handle answers one request.
func (a *Agent) Handle(ctx context.Context, r *Request) Response {
	a.init()
	if _, err := a.verify(r); err != nil {
		return Response{Err: err.Error()}
	}
	switch r.Op {
	case "run":
		if err := checkCommand(r.Args); err != nil {
			return Response{Err: err.Error()}
		}
		rc, out := a.exec(ctx, r.Args)
		return Response{OK: true, RC: rc, Out: out}
	case "enqueue": // a local caller asks the OTHER side to run Inner
		if r.Inner == nil || r.Inner.TID != r.TID || r.Inner.Op != "run" {
			return Response{Err: "enqueue needs a signed run request of the same tunnel"}
		}
		if err := checkCommand(r.Inner.Args); err != nil {
			return Response{Err: err.Error()}
		}
		a.mu.Lock()
		a.queue[r.TID] = append(a.queue[r.TID], queued{id: r.Nonce, req: r.Inner})
		a.mu.Unlock()
		return Response{OK: true, ID: r.Nonce}
	case "poll": // the other side's agent collects one queued request
		a.mu.Lock()
		defer a.mu.Unlock()
		q := a.queue[r.TID]
		if len(q) == 0 {
			return Response{OK: true}
		}
		a.queue[r.TID] = q[1:]
		return Response{OK: true, Inner: q[0].req, ID: q[0].id}
	case "result": // ... and posts what it got
		a.mu.Lock()
		a.results[r.ID] = r
		a.mu.Unlock()
		return Response{OK: true}
	case "wait":
		a.mu.Lock()
		res, ok := a.results[r.ID]
		if ok {
			delete(a.results, r.ID)
		}
		a.mu.Unlock()
		if !ok {
			return Response{OK: true}
		}
		return Response{OK: true, Done: true, RC: res.RC, Out: res.Out}
	}
	return Response{Err: "unknown op"}
}

func (a *Agent) exec(ctx context.Context, args []string) (int, string) {
	a.running.Lock()
	defer a.running.Unlock()
	return a.Exec(ctx, args)
}

func (a *Agent) runManage(ctx context.Context, args []string) (int, string) {
	ctx, cancel := context.WithTimeout(ctx, runTimeout)
	defer cancel()
	full := append(append([]string{}, args...), "--yes")
	c := exec.CommandContext(ctx, "bash", append([]string{a.Manage}, full...)...)
	out, err := c.CombinedOutput()
	if len(out) > maxOutput {
		out = append(out[:maxOutput], []byte("\n[output truncated]")...)
	}
	rc := 0
	if err != nil {
		var ee *exec.ExitError
		if errors.As(err, &ee) {
			rc = ee.ExitCode()
		} else {
			rc, out = 125, append(out, []byte("\n"+err.Error())...)
		}
	}
	return rc, string(out)
}

// Serve accepts on ln until ctx ends.
func (a *Agent) Serve(ctx context.Context, ln net.Listener) error {
	a.init()
	go func() { <-ctx.Done(); ln.Close() }()
	for {
		c, err := ln.Accept()
		if err != nil {
			if ctx.Err() != nil {
				return nil
			}
			continue
		}
		go a.serveConn(ctx, c)
	}
}

func (a *Agent) serveConn(ctx context.Context, c net.Conn) {
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(runTimeout + 10*time.Second))
	br := bufio.NewReaderSize(c, 4096)
	line, err := br.ReadSlice('\n')
	if err != nil || len(line) > maxRequest {
		return
	}
	var r Request
	resp := Response{Err: "bad request"}
	if json.Unmarshal(line, &r) == nil {
		resp = a.Handle(ctx, &r)
	}
	b, _ := json.Marshal(resp)
	_, _ = c.Write(append(b, '\n'))
}

// Poll is the Iran side's loop for one tunnel: collect requests the foreign side
// queued (through the management mapping at peerAddr), run them here, and post
// the results back.
func (a *Agent) Poll(ctx context.Context, name, peerAddr string) {
	a.init()
	t := time.NewTicker(pollEvery)
	defer t.Stop()
	for {
		select {
		case <-ctx.Done():
			return
		case <-t.C:
		}
		token, err := TokenOf(a.Etc, name)
		if err != nil {
			continue
		}
		p := &Request{Op: "poll"}
		Sign(token, p)
		resp, err := Call(ctx, peerAddr, p)
		if err != nil || !resp.OK || resp.Inner == nil {
			continue
		}
		// the queued request was signed by the foreign side with the same token: check it like any other
		inner := resp.Inner
		rc, out := 1, ""
		if _, err := a.verify(inner); err != nil {
			out = "refused: " + err.Error()
		} else if err := checkCommand(inner.Args); err != nil {
			out = "refused: " + err.Error()
		} else {
			rc, out = a.exec(ctx, inner.Args)
		}
		res := &Request{Op: "result", ID: resp.ID, RC: rc, Out: out}
		Sign(token, res)
		_, _ = Call(ctx, peerAddr, res)
	}
}

// --- the caller -------------------------------------------------------------------------------------------------

// Call sends one request and reads the answer.
func Call(ctx context.Context, addr string, r *Request) (Response, error) {
	d := net.Dialer{Timeout: 10 * time.Second}
	c, err := d.DialContext(ctx, "tcp", addr)
	if err != nil {
		return Response{}, err
	}
	defer c.Close()
	_ = c.SetDeadline(time.Now().Add(runTimeout + 20*time.Second))
	b, _ := json.Marshal(r)
	if _, err := c.Write(append(b, '\n')); err != nil {
		return Response{}, err
	}
	line, err := bufio.NewReaderSize(c, 64<<10).ReadBytes('\n')
	if err != nil && len(line) == 0 {
		return Response{}, err
	}
	var resp Response
	if err := json.Unmarshal(line, &resp); err != nil {
		return Response{}, fmt.Errorf("bad answer: %v", err)
	}
	return resp, nil
}

// RunRemote asks the agent at addr to run args for tunnel NAME (Iran side calling abroad).
func RunRemote(ctx context.Context, etc, name, addr string, args []string) (int, string, error) {
	token, err := TokenOf(etc, name)
	if err != nil {
		return 0, "", err
	}
	r := &Request{Op: "run", Args: args}
	Sign(token, r)
	resp, err := Call(ctx, addr, r)
	if err != nil {
		return 0, "", err
	}
	if !resp.OK {
		return 0, "", errors.New(resp.Err)
	}
	return resp.RC, resp.Out, nil
}

// RunViaQueue asks the other side to run args by queueing it in the local agent
// at local and waiting for the other side's agent to collect and answer it
// (foreign side calling Iran).
func RunViaQueue(ctx context.Context, etc, name, local string, args []string) (int, string, error) {
	token, err := TokenOf(etc, name)
	if err != nil {
		return 0, "", err
	}
	inner := &Request{Op: "run", Args: args}
	Sign(token, inner)
	enq := &Request{Op: "enqueue", Inner: inner}
	Sign(token, enq)
	resp, err := Call(ctx, local, enq)
	if err != nil {
		return 0, "", err
	}
	if !resp.OK {
		return 0, "", errors.New(resp.Err)
	}
	deadline := time.Now().Add(waitTimeout)
	for time.Now().Before(deadline) {
		select {
		case <-ctx.Done():
			return 0, "", ctx.Err()
		case <-time.After(time.Second):
		}
		w := &Request{Op: "wait", ID: resp.ID}
		Sign(token, w)
		r, err := Call(ctx, local, w)
		if err == nil && r.OK && r.Done {
			return r.RC, r.Out, nil
		}
	}
	return 0, "", errors.New("the other side did not collect the request (is the tunnel up and the Iran agent running?)")
}

// --- command line -----------------------------------------------------------------------------------------------

// Main is `hwtunnel peer ...`.
//
//	hwtunnel peer serve [--listen 127.0.0.1:59111] [--etc DIR] [--manage FILE]
//	hwtunnel peer run   --tunnel NAME --to ADDR   CMD ARGS...   (Iran: run CMD abroad, through the mapping ADDR)
//	hwtunnel peer queue --tunnel NAME [--local ADDR] CMD ARGS... (abroad: have Iran run CMD)
func Main(args []string, stdout, stderr *os.File) int {
	if len(args) == 0 {
		fmt.Fprintln(stderr, "usage: hwtunnel peer serve|run|queue ...")
		return 2
	}
	sub, args := args[0], args[1:]
	opt := map[string]string{"listen": DefaultAgentAddr, "etc": "/opt/hwtunnel/etc", "manage": "/opt/hwtunnel/bin/manage.sh", "local": DefaultAgentAddr}
	var rest []string
	for i := 0; i < len(args); i++ {
		if k := strings.TrimPrefix(args[i], "--"); k != args[i] && i+1 < len(args) && (k == "listen" || k == "etc" || k == "manage" || k == "tunnel" || k == "to" || k == "local") {
			opt[k] = args[i+1]
			i++
			continue
		}
		rest = append(rest, args[i])
	}
	ctx := context.Background()
	switch sub {
	case "serve":
		host, _, err := net.SplitHostPort(opt["listen"])
		if err != nil || !net.ParseIP(host).IsLoopback() {
			fmt.Fprintln(stderr, "peer serve listens on loopback only")
			return 2
		}
		ln, err := net.Listen("tcp", opt["listen"])
		if err != nil {
			fmt.Fprintln(stderr, err)
			return 1
		}
		a := &Agent{Etc: opt["etc"], Manage: opt["manage"]}
		// Iran side: poll every tunnel that has a management mapping (NAME.peer holds port=N)
		files, _ := filepath.Glob(filepath.Join(opt["etc"], "*.peer"))
		for _, f := range files {
			b, _ := os.ReadFile(f)
			for _, l := range strings.Split(string(b), "\n") {
				if p, ok := strings.CutPrefix(strings.TrimSpace(l), "port="); ok {
					if _, err := strconv.Atoi(p); err == nil {
						go a.Poll(ctx, strings.TrimSuffix(filepath.Base(f), ".peer"), "127.0.0.1:"+p)
					}
				}
			}
		}
		fmt.Fprintf(stdout, "hwtunnel peer agent on %s (%d tunnels polled)\n", opt["listen"], len(files))
		_ = a.Serve(ctx, ln)
		return 0
	case "run", "queue":
		if opt["tunnel"] == "" || len(rest) == 0 || (sub == "run" && opt["to"] == "") {
			fmt.Fprintln(stderr, "usage: hwtunnel peer run --tunnel NAME --to ADDR CMD...  |  peer queue --tunnel NAME CMD...")
			return 2
		}
		if err := checkCommand(rest); err != nil {
			fmt.Fprintln(stderr, err)
			return 2
		}
		var rc int
		var out string
		var err error
		if sub == "run" {
			rc, out, err = RunRemote(ctx, opt["etc"], opt["tunnel"], opt["to"], rest)
		} else {
			rc, out, err = RunViaQueue(ctx, opt["etc"], opt["tunnel"], opt["local"], rest)
		}
		if err != nil {
			fmt.Fprintln(stderr, "peer:", err)
			return 1
		}
		fmt.Fprint(stdout, out)
		return rc
	}
	fmt.Fprintln(stderr, "unknown peer command", sub)
	return 2
}
