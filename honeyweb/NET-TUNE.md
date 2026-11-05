# net-tune: safe host tuning for an iptables tunnel

[فارسی](NET-TUNE_FA.md)

`net-tune.sh` tunes the network settings of the two servers of an **iptables (DNAT) tunnel** that carries TCP
traffic, such as an Xray VLESS inbound over TCP, WS+TLS or REALITY. One standalone Bash script runs on both servers
and is told which end it is on:

- `--role iran`: the entry server, where users connect.
- `--role finland`: the exit server, where the inbound (Xray) runs.

It reads the host first and changes as little as it can: keeping connections up and a reliable undo come before
squeezing out every setting.

## What it can and cannot do

- Host settings **cannot make the physical round trip between the two countries shorter** than the route allows.
  They can only stop the hosts from adding delay of their own: queues, resets, slow restarts after a pause.
- **BBR does not guarantee more speed or lower delay on every network.** It usually helps on long paths with some
  loss, but not always.

## Install and run (on each server, as root)

```bash
curl -fsSLo net-tune.sh https://raw.githubusercontent.com/mahansh1999/HoneyWeb-Tunnel/net-tune-v1.0.0/honeyweb/net-tune.sh
echo "76faf5902cee21849ee6dc2f2ea121d9db345a13c8e215a074e3c0415775914a  net-tune.sh" | sha256sum -c -        # must print: net-tune.sh: OK

bash net-tune.sh --dry-run --role iran --port 443        # on the entry server: shows the plan, changes nothing
bash net-tune.sh --apply   --role iran --port 443        # asks 'yes', applies, then asks you to keep it

bash net-tune.sh --dry-run --role finland --port 443     # on the exit server
bash net-tune.sh --apply   --role finland --port 443
```

`--port` is the TCP port of the inbound that the tunnel carries. The link above names a fixed version: what you run is
what was tested. If GitHub is not reachable from the server, download the file on another computer, check the
same sha256 there, and copy it over with `scp`.

| Command | What it does |
|---|---|
| `--status` | What the host runs now: kernel, memory, interface and queues, TCP settings, conntrack, counters, the sessions on `--port`. Changes nothing. |
| `--dry-run` | The plan: every value that would change, from what to what, and why. It also lists what is left alone and why. Changes nothing. |
| `--apply` | Applies the plan (see "How a change is applied"). Asks for `yes` first. `--yes` skips the questions, for scripts. |
| `--rollback` | Undoes the last applied run, or the one given with `--backup DIR`. |

Other options:
- `--check HOST:PORT` (repeatable): a TCP connection that must still work after the change.
- `--guard SECONDS`: how long the automatic undo waits. The default is 240; `0` turns it off.

## What it changes, and when

Each item applies only when the condition holds. Otherwise the current value is kept and the dry run says why.

**Exit server (`--role finland`), and an entry server where a program listens on `--port` (a relay):** TCP
connections of the tunnel end here.

| Setting | New value | Only when | Why |
|---|---|---|---|
| `net.ipv4.tcp_congestion_control` | `bbr` | the kernel has BBR and the current value is the stock `cubic`/`reno` | BBR paces sending by measured bandwidth and RTT instead of filling queues until loss. New connections only. |
| `net.core.default_qdisc` + the queue(s) of the main interface | `fq` | BBR is in use, `sch_fq` exists, and the queues are the stock `fq_codel`/`pfifo_fast` (no shaping) | Exact per-flow pacing for BBR. The queue is swapped in place; nothing is restarted. |
| `net.ipv4.tcp_slow_start_after_idle` | `0` | it is `1` | A connection that pauses keeps its sending window instead of starting slow again. |
| `net.ipv4.tcp_notsent_lowat` | `131072` | it is unlimited | At most 128 KiB waits unsent in a socket. A new request is not stuck behind megabytes of queued download, and kernel memory stays small. |
| `net.ipv4.tcp_mtu_probing` | `1` | it is `0` | When a path silently drops large packets (filtered ICMP), TCP finds a working size instead of hanging. The interface MTU is not touched. |
| `net.ipv4.tcp_rmem` (maximum) | 8 MiB | TCP memory pressure happened since boot and the maximum is larger | Under pressure the kernel shrinks every socket's window to a few KB. |
| `somaxconn`, `tcp_max_syn_backlog` | 4096 | the accept queue overflowed | |

**Entry server that forwards with DNAT (`--role iran`, nothing listens on `--port`):** no TCP connection of the
tunnel ends here. Congestion control and TCP buffers of this host do not affect the tunnel, so they are not changed.

| Setting | New value | Only when | Why |
|---|---|---|---|
| `net.netfilter.nf_conntrack_tcp_be_liberal` | `1` | conntrack is loaded and it is `0` | Conntrack marks a packet of a live connection INVALID when it looks out of window (loss, reordering, large windows). That packet is not NATed. It reaches the entry server's own TCP stack, which answers with a reset that cuts the user's connection. Liberal mode keeps such packets NATed; resets and SYNs are still checked. |
| queue of the main interface | `fq_codel` | it is a plain FIFO (`pfifo_fast`) | Fair queueing and a short queue for forwarded flows. |

**Both:**
- `nf_conntrack_max` is raised when the table is half full, at most to about 2 % of the RAM.
- `netdev_max_backlog` is raised to 4096 when the kernel dropped received packets.

**Never touched:**
- iptables/nftables, routes, addresses, MTU and ports;
- Xray and its config, the tunnel, any service;
- reboots and network restarts.

A key that an administrator set in `/etc/sysctl.conf` or `/etc/sysctl.d/` is left as it is and reported. So is a
congestion control or queue that somebody chose on purpose.

## How a change is applied

1. **Checks before anything changes:** root, Linux kernel 4.9 or newer, bash 4.4, the needed commands, at least 1 MiB
   free for the backup. If one fails, the tool stops and changes nothing.
2. **Backup** to `/var/backups/hw-net-tune/<time>/`: the old values, the queues, the old files, and a `rollback.sh`
   that restores all of them. The tool checks that the `rollback.sh` is complete before it goes on.
3. **Guard:** a systemd timer (or a background process) runs `rollback.sh` by itself after `--guard` seconds, unless
   the run completes. A dropped SSH session or a killed run therefore rolls back on its own.
4. **Runtime change.** Nothing is saved for the next boot yet.
5. **Checks after the change.** Any failure rolls everything back at once. The tool checks that:
   - every value reads back as set;
   - the queues are the planned ones;
   - the default route, the addresses and the MTU are unchanged;
   - the firewall ruleset hash is unchanged;
   - the inbound port still listens;
   - TCP still reaches the tunnel's far end (forwarding mode), `127.0.0.1:PORT` (endpoint mode), and every `--check`.
6. **Your confirmation (interactive run):** press Enter within 60 s to keep the change. No answer means rollback.
7. **Saved for boot:** `/etc/sysctl.d/90-hw-net-tune.conf`, and `/etc/modules-load.d/hw-net-tune.conf` for
   `tcp_bbr`, `sch_fq` and `nf_conntrack`, which must be loaded before the file is applied at boot.
   The file is loaded once more and checked, and the guard is cancelled.

Running `--apply` again changes nothing when the host already matches. `--rollback` undoes one run at a time, newest
first. Each backup also has its own `rollback.sh`.

The log is `/var/log/hw-net-tune.log`. It holds times, keys and values only, never addresses.

Exit codes:

| Code | Meaning |
|---|---|
| 0 | done, or nothing to do |
| 1 | refused, nothing changed |
| 2 | wrong usage |
| 3 | a check failed and everything was rolled back |
| 4 | the rollback itself reported an error: the saved state is in the backup folder |

## Tested

`scripts/lab/test-net-tune.sh` of the HoneyWeb Tunnel workspace runs in network and mount namespaces: no real host
setting is touched. It checks:
- status, dry run, apply and an idempotent rerun;
- rollback, including a second rollback that is refused;
- a key owned by an administrator;
- a full disk;
- a failed check followed by automatic rollback;
- interactive keep, timeout and refusal;
- a killed run, rolled back by the guard;
- forwarding mode with DNAT;
- the queue path, including a custom queue that is left alone;
- that the lab host itself is unchanged.
