#!/usr/bin/env bash
# net-tune.sh: safe host network tuning for the two ends of an iptables (DNAT) tunnel that carries TCP traffic,
# for example an Xray VLESS inbound over TCP, WS+TLS or REALITY. Part of HoneyWeb Tunnel. Run as root on each server:
#
#   net-tune.sh --status   [--role iran|finland] [--port N]          what the host runs now (changes nothing)
#   net-tune.sh --dry-run  --role iran|finland [--port N]            the plan, its effect and risk (changes nothing)
#   net-tune.sh --apply    --role iran|finland [--port N] [--yes] [--check HOST:PORT]... [--guard SECONDS]
#   net-tune.sh --rollback [--backup DIR] [--yes]                    undo the last applied run (or the one in DIR)
#
# --role iran     the entry server. If it forwards the port with DNAT (the kernel relays the packets), no TCP
#                 connection ends there: congestion control and TCP buffers of this host do not touch the tunnel's
#                 traffic, so only the forwarding path is tuned (conntrack and the queue of the network interface).
#                 If a program listens on --port (a relay such as haproxy, nginx or gost), it is tuned like an endpoint.
# --role finland  the exit server, where the inbound (Xray) ends the users' TCP connections: congestion control
#                 (BBR with the fq qdisc), restart after idle, unsent-queue limit and MTU probing.
#
# Every value is chosen from what the host shows: kernel and modules, memory, the interface's queues and the current
# values. A value somebody already set (a file in /etc/sysctl.d, /etc/sysctl.conf, or a non-default runtime value)
# is left alone and reported. Never touched: iptables/nftables, routes, addresses, MTU, ports, services, Xray, the
# tunnel. No reboot, no restart, no network restart.
#
# --apply: backup -> a rollback guard that fires by itself unless the run completes -> runtime change -> checks (values
# read back, default route, addresses, MTU, firewall ruleset hash, listener, TCP reachability) -> Enter within 60 s to
# keep (interactive) -> /etc/sysctl.d/90-hw-net-tune.conf -> done. Any failed step rolls everything back.
# Backups: /var/backups/hw-net-tune/<time>/ (rollback.sh in each). Log: /var/log/hw-net-tune.log (no addresses).
set -uo pipefail
umask 022
VERSION=1.0.0
BKROOT=/var/backups/hw-net-tune
PERSIST=/etc/sysctl.d/90-hw-net-tune.conf
MODLOAD=/etc/modules-load.d/hw-net-tune.conf
LOG=/var/log/hw-net-tune.log
LOCK=/run/hw-net-tune.lock

if [ -t 1 ]; then B=$'\033[1m'; G=$'\033[32m'; Y=$'\033[33m'; R=$'\033[31m'; N=$'\033[0m'; else B=; G=; Y=; R=; N=; fi
say() { printf '%s\n' "$*" 2>/dev/null || true; }
hdr() { say ""; say "${B}== $*${N}"; }
warn() { say "${Y}! $*${N}"; }
die() { printf '%s\n' "${R}net-tune: $1${N}" >&2; exit "${2:-1}"; }
log() { [ "$MODE" = apply ] || [ "$MODE" = rollback ] || return 0; printf '%s %s\n' "$(date -u +%FT%TZ)" "$*" >> "$LOG" 2>/dev/null || true; }
tty_ok() { [ -r /dev/tty ] && [ -w /dev/tty ] && { : </dev/tty; } 2>/dev/null; }

SELF=$0; [ -f "$SELF" ] || SELF="bash net-tune.sh"
usage() { cat <<EOF
net-tune $VERSION: safe host network tuning for an iptables (DNAT) TCP tunnel. Run as root.
  $SELF --status   [--role iran|finland] [--port N]
  $SELF --dry-run  --role iran|finland [--port N]
  $SELF --apply    --role iran|finland [--port N] [--yes] [--check HOST:PORT]... [--guard SECONDS]
  $SELF --rollback [--backup DIR] [--yes]
EOF
  exit "${1:-2}"; }
MODE=; ROLE=; PORT=; YES=0; GUARD=240; BACKUP=; CHECKS=()
while [ $# -gt 0 ]; do
  case "$1" in
    --status) MODE=status;; --dry-run) MODE=dry-run;; --apply) MODE=apply;; --rollback) MODE=rollback;;
    --role) ROLE=${2:-}; shift;; --role=*) ROLE=${1#*=};;
    --port) PORT=${2:-}; shift;; --port=*) PORT=${1#*=};;
    --check) CHECKS+=("${2:-}"); shift;; --check=*) CHECKS+=("${1#*=}");;
    --guard) GUARD=${2:-}; shift;; --guard=*) GUARD=${1#*=};;
    --backup) BACKUP=${2:-}; shift;; --backup=*) BACKUP=${1#*=};;
    --yes|-y) YES=1;; --version) say "net-tune $VERSION"; exit 0;; -h|--help) usage 0;;
    *) die "unknown argument '$1' (see --help)" 2;;
  esac; shift
done
[ -n "$MODE" ] || usage 2
case "$ROLE" in ""|iran|finland) ;; entry) ROLE=iran;; exit|kharej|foreign) ROLE=finland;; *) die "--role must be iran or finland" 2;; esac
[ -z "$PORT" ] || [[ "$PORT" =~ ^[0-9]+$ && "$PORT" -ge 1 && "$PORT" -le 65535 ]] || die "--port must be 1-65535" 2
[[ "$GUARD" =~ ^[0-9]+$ ]] && { [ "$GUARD" = 0 ] || [ "$GUARD" -ge 90 ]; } || die "--guard must be 0 (off) or at least 90 seconds" 2
for c in "${CHECKS[@]}"; do [[ "$c" =~ ^[A-Za-z0-9.:-]+:[0-9]+$ ]] || die "--check must be HOST:PORT" 2; done

# ---------- prerequisites (nothing is changed before all of these pass) ----------
[ "$(uname -s)" = Linux ] || die "only Linux is supported"
[ "$(id -u)" = 0 ] || die "run as root (sudo -i first)"
{ [ "${BASH_VERSINFO[0]}" -gt 4 ] || { [ "${BASH_VERSINFO[0]}" = 4 ] && [ "${BASH_VERSINFO[1]}" -ge 4 ]; }; } || die "bash 4.4 or newer is needed"
[ -d /proc/sys/net/ipv4 ] || die "/proc/sys/net is not available here (container without its own network sysctls?)"
for x in awk sed grep sort ip ss sha256sum; do command -v "$x" >/dev/null || die "missing command: $x"; done
HAVE_TC=0; command -v tc >/dev/null && HAVE_TC=1
KV=$(uname -r); KMAJ=${KV%%.*}; KMIN=${KV#*.}; KMIN=${KMIN%%[!0-9]*}
kge() { [ "$KMAJ" -gt "$1" ] || { [ "$KMAJ" -eq "$1" ] && [ "$KMIN" -ge "$2" ]; }; }
kge 4 9 || die "kernel $KV is older than 4.9: not supported, nothing changed"

# ---------- reading the host ----------
pk() { printf '/proc/sys/%s' "${1//.//}"; }
sk() { local f; f=$(pk "$1"); [ -r "$f" ] || return 1; tr '\t' ' ' < "$f" | tr -s ' ' | sed 's/ *$//'; }
wk() { local f; f=$(pk "$1"); [ -w "$f" ]; }
cnt() {  # cnt TcpExt TCPMemoryPressures -> counter since boot (0 if unknown)
  awk -v p="$1:" -v k="$2" '$1 == p { if (!(p in h)) { h[p]=1; for (i=2;i<=NF;i++) n[i]=$i; next }
    for (i=2;i<=NF;i++) if (n[i] == k) { print $i; f=1; exit } } END { if (!f) print 0 }' /proc/net/netstat /proc/net/snmp 2>/dev/null; }
softnet_drops() { local d=0 a b; while read -r _ a b _; do d=$((d + 0x$a)); done < /proc/net/softnet_stat; echo "$d"; }
modok() {  # module present: loaded, built in, or installed for this kernel
  grep -qw "^$1" /proc/modules 2>/dev/null && return 0
  grep -qs "/$1\.ko" "/lib/modules/$KV/modules.builtin" && return 0
  modinfo -n "$1" >/dev/null 2>&1 && return 0
  find "/lib/modules/$KV" -name "$1.ko*" 2>/dev/null | grep -q .; }
modbuiltin() { grep -qs "/$1\.ko" "/lib/modules/$KV/modules.builtin"; }

admin_files() {  # sysctl files an administrator owns (vendor defaults in /usr/lib and /lib are not)
  local f; for f in /etc/sysctl.conf /etc/sysctl.d/*.conf /run/sysctl.d/*.conf /usr/local/lib/sysctl.d/*.conf; do
    [ -f "$f" ] && [ "$(readlink -f "$f")" != "$(readlink -f "$PERSIST")" ] && echo "$f"; done | sort -u; }
file_keys() { sed -nE 's/^[[:space:]]*-?([A-Za-z0-9_./*-]+)[[:space:]]*=.*/\1/p' "$1" 2>/dev/null | tr '/' '.'; }
owner_of() {  # owner_of KEY -> the admin file that sets KEY, if any
  local f; while read -r f; do file_keys "$f" | grep -qxF "$1" && { echo "$f"; return 0; }; done < <(admin_files); return 1; }
boot_last() {  # boot_last KEY -> the file systemd-sysctl applies last for KEY (later files win)
  local d f b; declare -A seen=(); local list=()
  for d in /etc/sysctl.d /run/sysctl.d /usr/local/lib/sysctl.d /usr/lib/sysctl.d /lib/sysctl.d; do
    for f in "$d"/*.conf; do [ -e "$f" ] || continue; b=${f##*/}; [ -n "${seen[$b]:-}" ] && continue; seen[$b]=1; list+=("$b|$f"); done
  done
  printf '%s\n' "${list[@]}" | sort -t'|' -k1,1 | cut -d'|' -f2 | while read -r f; do file_keys "$f" | grep -qxF "$1" && echo "$f"; done | tail -1; }

DEV=$(ip -4 route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
[ -n "$DEV" ] || DEV=$(ip -6 route show default 2>/dev/null | awk '{for (i=1;i<NF;i++) if ($i=="dev") {print $(i+1); exit}}')
qd_lines() { [ "$HAVE_TC" = 1 ] && [ -n "$DEV" ] && tc qdisc show dev "$DEV" 2>/dev/null |
  awk '$1=="qdisc" && $2!="ingress" && $2!="clsact" {p="root"; for (i=4;i<NF;i++) if ($i=="parent") p=$(i+1); print $2, p, ($0 ~ / maxrate /) ? "custom" : "plain"}'; }

dnat_dests() {  # unique DNAT destinations (IPv4), from iptables and nftables, read only
  local own a; own=" $(ip -o -4 addr show 2>/dev/null | awk '{sub(/\/.*/, "", $4); printf "%s ", $4}')"
  { iptables-save -t nat 2>/dev/null; [ -s /proc/net/ip_tables_names ] && iptables-legacy-save -t nat 2>/dev/null
    command -v nft >/dev/null && nft list ruleset 2>/dev/null; } |
    grep -oE -- '(--to-destination|dnat (ip )?to) [0-9]+(\.[0-9]+){3}' | grep -oE '[0-9]+(\.[0-9]+){3}' | sort -u |
    while read -r a; do [[ "$own" == *" $a "* ]] || echo "$a"; done; }  # DNAT to this host itself is not a tunnel
fw_hash() { { iptables-save 2>/dev/null; ip6tables-save 2>/dev/null; command -v nft >/dev/null && nft list ruleset 2>/dev/null; } |
  sed -E '/^#/d; s/\[[0-9]+:[0-9]+\]//g; s/counter packets [0-9]+ bytes [0-9]+//g' | sha256sum | cut -c1-16; }
net_state() {  # route, addresses and MTU: must be identical before and after (lifetimes such as an RA route's
  # "expires 1798sec" count down by themselves and are left out)
  { { ip -4 route show default; ip -6 route show default; } | sed -E 's/ (expires|age|used) [0-9]+sec//g'
    ip -o addr show | awk '{print $2, $3, $4}'
    ip -o link show | awk '{for (i=1;i<NF;i++) if ($i=="mtu") print $2, $(i+1)}'; } 2>/dev/null | sha256sum | cut -c1-16; }
listening() { [ -n "$PORT" ] && ss -Htln "( sport = :$PORT )" 2>/dev/null | grep -q .; }
tcp_ok() { local h=${1%:*} p=${1##*:}; timeout 5 bash -c "exec 3<>/dev/tcp/$h/$p" 2>/dev/null; }

facts() {
  # in a subshell: os-release defines VERSION too, which must not replace this tool's own
  OS=$(. /etc/os-release 2>/dev/null; echo "${ID:-linux}-${VERSION_ID:-?}"); VIRT=$(systemd-detect-virt 2>/dev/null || echo unknown)
  MEM_MIB=$(awk '/^MemTotal:/ {print int($2/1024)}' /proc/meminfo); CPUS=$(nproc 2>/dev/null || echo 1)
  CC=$(sk net.ipv4.tcp_congestion_control || echo ?); CCAV=$(sk net.ipv4.tcp_available_congestion_control || echo "")
  BBR=0; { [[ " $CCAV " == *" bbr "* ]] || modok tcp_bbr; } && BBR=1
  FQ=0; modok sch_fq && FQ=1; FQC=0; modok sch_fq_codel && FQC=1
  CT=0; [ -r "$(pk net.netfilter.nf_conntrack_max)" ] && CT=1
  CT_MAX=$(sk net.netfilter.nf_conntrack_max || echo 0); CT_CNT=$(sk net.netfilter.nf_conntrack_count || echo 0)
  FWD=$(sk net.ipv4.ip_forward || echo 0); mapfile -t DNAT < <(dnat_dests)
  LISTEN=0; listening && LISTEN=1
  MODE_NET=endpoint
  if [ "$ROLE" = iran ] && [ "$LISTEN" = 0 ] && [ "$FWD" = 1 ] && [ "${#DNAT[@]}" -gt 0 ]; then MODE_NET=forward; fi
  PRESS=$(cnt TcpExt TCPMemoryPressures); LOVF=$(cnt TcpExt ListenOverflows); SNDROP=$(softnet_drops)
  RETR=$(cnt Tcp RetransSegs); OUTS=$(cnt Tcp OutSegs); RSTS=$(cnt Tcp OutRsts)
  CT_FULL=0; [ "$CT" = 1 ] && CT_FULL=$(dmesg 2>/dev/null | grep -ci 'nf_conntrack: table full' || true)
  mapfile -t QD < <(qd_lines)
}

# ---------- the plan ----------
PK=(); PN=(); PO=(); PW=(); SKIP=(); NOTE=(); QREP=(); QFROM=""; QTO=""; MODS=()
plan_key() {  # plan_key KEY NEW WHY  (skips, with the reason, anything that is missing, read-only or owned)
  local k=$1 v=$2 why=$3 cur own; cur=$(sk "$k") || { SKIP+=("$k: not available on this kernel or in this container"); return 1; }
  [ "$cur" = "$v" ] && return 1
  if own=$(owner_of "$k"); then SKIP+=("$k = $cur: set in $own by the administrator; left unchanged"); return 1; fi
  wk "$k" || { SKIP+=("$k: read-only here (container or locked); left $cur"); return 1; }
  PK+=("$k"); PN+=("$v"); PO+=("$cur"); PW+=("$why")
}
qd_simple() { local l; [ ${#QD[@]} -gt 0 ] || return 1; for l in "${QD[@]}"; do set -- $l
  case "$1" in mq|pfifo_fast|fq_codel|fq|pfifo|bfifo) ;; *) return 1;; esac; [ "$3" = plain ] || return 1; done; }
plan_qdisc() {  # plan_qdisc KIND WHY: the live interface and the default for new ones
  local want=$1 why=$2 l kinds="" n=0
  if [ "$want" = fq ] && [ "$FQ" = 0 ]; then SKIP+=("qdisc fq: the sch_fq module is not available for kernel $KV"); return; fi
  if [ "$want" = fq_codel ] && [ "$FQC" = 0 ]; then SKIP+=("qdisc fq_codel: not available for kernel $KV"); return; fi
  # The live interface and the default (which keeps it after reboot) change together or not at all. Forwarding
  # replaces only a plain FIFO (fq or fq_codel are both fine there); an endpoint moves the stock queues to fq.
  local from="pfifo_fast fq_codel pfifo bfifo" cdq rep=(); [ "$want" = fq_codel ] && from="pfifo_fast pfifo bfifo"
  cdq=$(sk net.core.default_qdisc) || { SKIP+=("qdisc: net.core.default_qdisc is not available here, so a change could not be kept after reboot; left unchanged"); return; }
  [ "$HAVE_TC" = 1 ] || { SKIP+=("qdisc of $DEV: the tc command is missing"); return; }
  [ -n "$DEV" ] || { SKIP+=("qdisc: no default route interface"); return; }
  if [ ${#QD[@]} -eq 1 ] && [ "${QD[0]%% *}" = noqueue ]; then SKIP+=("qdisc of $DEV: virtual interface without a queue (noqueue); left as is"); return; fi
  qd_simple || { SKIP+=("qdisc of $DEV: a custom or shaping setup ($(printf '%s; ' "${QD[@]}")); left unchanged"); return; }
  for l in "${QD[@]}"; do set -- $l; [ "$1" = mq ] && continue; kinds+=" $1"
    [ "$1" = "$want" ] && continue
    [[ " $from " == *" $1 "* ]] || continue
    rep+=("$2 $1"); n=$((n + 1)); done
  if [ "$cdq" != "$want" ]; then
    [[ " $from " == *" $cdq "* ]] || { [ "$want" = fq ] && SKIP+=("net.core.default_qdisc = $cdq: chosen by the administrator; queues left unchanged"); return; }
    plan_key net.core.default_qdisc "$want" "$why (interfaces brought up later and after reboot)" ||
      { SKIP+=("qdisc of $DEV: the default cannot be changed, so the interface is left as it is too"); return; }
  fi
  [ "$n" -gt 0 ] && { QREP=("${rep[@]}"); QFROM=$(printf '%s\n' $kinds | sort -u | tr '\n' ' '); QTO=$want; NOTE+=("qdisc of $DEV: $QFROM-> $want on $n queue(s): $why. Swapping a queue is instant; packets waiting in it at that moment (normally none) are dropped and resent by TCP"); }
}

build_plan() {
  if [ "$MODE_NET" = endpoint ]; then
    # Congestion control: BBR only from the kernel's stock choice, only when the kernel has it.
    if [ "$CC" = bbr ]; then :
    elif [ "$BBR" = 0 ]; then SKIP+=("tcp_congestion_control = $CC: this kernel ($KV) has no BBR module; left unchanged")
    elif [ "$CC" != cubic ] && [ "$CC" != reno ]; then SKIP+=("tcp_congestion_control = $CC: chosen by the administrator; left unchanged")
    elif ! kge 4 13 && [ "$FQ" = 0 ]; then SKIP+=("tcp_congestion_control: BBR before kernel 4.13 needs the fq qdisc, which is missing; left $CC")
    else plan_key net.ipv4.tcp_congestion_control bbr "BBR paces sending by measured bandwidth and RTT instead of filling queues until loss: steadier throughput and lower queueing delay on a long, lossy path. New connections only; existing ones keep $CC until they reconnect" &&
           { modbuiltin tcp_bbr || MODS+=(tcp_bbr); }; fi
    if [ "$CC" = bbr ] || [[ " ${PN[*]} " == *" bbr "* ]]; then
      plan_qdisc fq "fq gives BBR exact per-flow pacing and per-flow fairness"; [ -n "$QTO" ] && { modbuiltin sch_fq || MODS+=(sch_fq); }
    fi
    local ssi; ssi=$(sk net.ipv4.tcp_slow_start_after_idle || echo "")
    [ "$ssi" = 1 ] && plan_key net.ipv4.tcp_slow_start_after_idle 0 "a connection that paused (a web page between clicks, a long-lived WS stream) keeps its sending window instead of restarting slow: no slow first second after every pause. Applies to existing connections at once"
    local nl; nl=$(sk net.ipv4.tcp_notsent_lowat || echo "")
    if [ "$nl" = 4294967295 ] || [ "$nl" = -1 ]; then
      plan_key net.ipv4.tcp_notsent_lowat 131072 "caps data waiting unsent in each socket at 128 KiB (unlimited before): the proxy reads from the far side only as fast as the user's path drains, so a new request is not stuck behind megabytes of queued download, and kernel memory per connection stays small"
    elif [ -n "$nl" ]; then NOTE+=("tcp_notsent_lowat is already limited ($nl); left unchanged"); fi
    local mp; mp=$(sk net.ipv4.tcp_mtu_probing || echo "")
    [ "$mp" = 0 ] && plan_key net.ipv4.tcp_mtu_probing 1 "if a path drops large packets without telling (ICMP filtered, common on Iranian routes), TCP finds a working packet size after a timeout instead of hanging. Only acts on such a black hole; the interface MTU is not changed"
    local r1 r2 r3 w1 w2 w3
    read -r r1 r2 r3 <<< "$(sk net.ipv4.tcp_rmem || echo "")"; read -r w1 w2 w3 <<< "$(sk net.ipv4.tcp_wmem || echo "")"
    if [ -n "${r3:-}" ] && [ "$PRESS" -gt 0 ] && [ "$r3" -gt 8388608 ]; then
      plan_key net.ipv4.tcp_rmem "$r1 $r2 8388608" "TCP memory pressure happened $PRESS times since boot; under pressure the kernel shrinks every socket's window to a few KB. An 8 MiB receive cap (was $r3) keeps per-socket memory bounded and still covers about 300 Mbit/s at 200 ms"
    elif [ -n "${r3:-}" ] && [ "$r3" -lt 6291456 ] && [ "$MEM_MIB" -ge 1024 ]; then
      plan_key net.ipv4.tcp_rmem "$r1 $r2 6291456" "the receive cap ($r3) is below the kernel default 6 MiB, which limits one connection's speed on a long path"
    fi
    if [ -n "${w3:-}" ] && [ "$w3" -lt 4194304 ] && [ "$MEM_MIB" -ge 1024 ]; then
      plan_key net.ipv4.tcp_wmem "$w1 $w2 4194304" "the send cap ($w3) is below the kernel default 4 MiB, which limits one connection's speed on a long path"
    fi
    if [ "$LOVF" -gt 0 ]; then
      local smc syn; smc=$(sk net.core.somaxconn || echo 4096); syn=$(sk net.ipv4.tcp_max_syn_backlog || echo 4096)
      [ "$smc" -lt 4096 ] && plan_key net.core.somaxconn 4096 "the accept queue overflowed $LOVF times since boot. Takes effect for listeners opened after the change (a restart of the service, which this tool does not do)"
      [ "$syn" -lt 4096 ] && plan_key net.ipv4.tcp_max_syn_backlog 4096 "the accept queue overflowed $LOVF times since boot"
    fi
  else
    NOTE+=("forwarding mode: the tunnel's packets are relayed by the kernel (DNAT), no TCP connection of the tunnel ends on this host, so congestion control ($CC) and TCP buffers here do not affect it and are left as they are")
    if [ "$CT" = 1 ]; then
      local lib; lib=$(sk net.netfilter.nf_conntrack_tcp_be_liberal || echo "")
      [ "$lib" = 0 ] && plan_key net.netfilter.nf_conntrack_tcp_be_liberal 1 "conntrack marks a packet of a live, forwarded connection INVALID when it looks out of its window (loss, reordering, large windows); such a packet is not NATed, reaches this host's own TCP stack and is answered with a reset that cuts the user's connection. Liberal mode keeps those packets NATed; resets and SYNs are still checked" &&
        MODS+=(nf_conntrack)
    else SKIP+=("conntrack: not loaded, nothing to tune"); fi
    plan_qdisc fq_codel "fq_codel keeps forwarded flows apart and the queue short (AQM) when the link is full"
  fi
  # Both modes: capacity of the connection table and of the receive backlog, only when they are short.
  if [ "$CT" = 1 ] && [ "$CT_MAX" -gt 0 ] && { [ $((CT_CNT * 2)) -ge "$CT_MAX" ] || [ "$CT_FULL" -gt 0 ]; }; then
    local cap=$(( MEM_MIB * 64 )) tgt=$(( CT_MAX * 2 )); [ "$tgt" -lt 262144 ] && tgt=262144; [ "$tgt" -gt "$cap" ] && tgt=$cap
    if [ "$tgt" -gt "$CT_MAX" ]; then
      if plan_key net.netfilter.nf_conntrack_max "$tgt" "the connection table is $((CT_CNT * 100 / CT_MAX))% full ($CT_CNT of $CT_MAX$( [ "$CT_FULL" -gt 0 ] && echo ", 'table full' logged $CT_FULL times")); when it is full every new connection is dropped. About 300 bytes per entry in use: at most $(( tgt * 320 / 1048576 )) MiB of $MEM_MIB MiB"; then
        [[ " ${MODS[*]} " == *" nf_conntrack "* ]] || MODS+=(nf_conntrack); fi
    else SKIP+=("nf_conntrack_max: table ${CT_CNT}/${CT_MAX} but memory ($MEM_MIB MiB) allows no larger table"); fi
  elif [ "$CT" = 1 ]; then NOTE+=("conntrack table $CT_CNT of $CT_MAX entries: enough headroom, left unchanged"); fi
  if [ "$SNDROP" -gt 0 ]; then
    local nb; nb=$(sk net.core.netdev_max_backlog || echo 1000)
    [ "$nb" -lt 4096 ] && plan_key net.core.netdev_max_backlog 4096 "the kernel dropped $SNDROP received packets because the per-CPU backlog ($nb) was full"
  fi
  case "$VIRT" in openvz|lxc|lxc-libvirt|systemd-nspawn|docker|podman) NOTE+=("this is a container ($VIRT): host-wide settings belong to the host and are skipped where read-only");; esac
}

# ---------- reports ----------
svc_nofile() {  # soft open-files limit of the program listening on --port
  [ -n "$PORT" ] || return 0; local pid lim
  pid=$(ss -Htlnp "( sport = :$PORT )" 2>/dev/null | grep -oE 'pid=[0-9]+' | head -1 | cut -d= -f2); [ -n "$pid" ] || return 0
  lim=$(awk '/^Max open files/ {print $4}' "/proc/$pid/limits" 2>/dev/null)
  [ -n "$lim" ] && [ "$lim" != unlimited ] && [ "$lim" -lt 65536 ] &&
    NOTE+=("the program on port $PORT ($(cat /proc/$pid/comm 2>/dev/null)) may open only $lim files; each user connection takes one. Raising it means LimitNOFILE in that service's unit and a restart: not done by this tool")
  return 0; }
sessions() {  # TCP sessions ending on --port: count, congestion control in use, RTT (no addresses)
  [ -n "$PORT" ] && [ "$MODE_NET" = endpoint ] || return 0
  local info; info=$(ss -tinH state established "( sport = :$PORT )" 2>/dev/null | grep -E '^[[:space:]]')
  [ -n "$info" ] || { say "  sessions on :$PORT  none right now"; return 0; }
  printf '%s\n' "$info" | awk -v p="$PORT" '{n++; for (i=1;i<=NF;i++) if ($i ~ /^(bbr|cubic|reno|htcp|vegas|westwood|bic)$/) c[$i]++}
    END {printf "  sessions on :%s  %d (", p, n; s=""; for (k in c) {printf "%s%s %d", s, k, c[k]; s=", "}; print ")"}'
  printf '%s\n' "$info" | grep -oE '(^|[[:space:]])rtt:[0-9.]+' | sed 's/.*://' | sort -n |
    awk '{v[NR]=$1} END {if (NR) {i=int((NR+1)*0.9); if (i>NR) i=NR; printf "  rtt of sessions    p50 %s ms, p90 %s ms\n", v[int((NR+1)/2)], v[i]}}'; }
report_host() {
  hdr "host"
  say "  role               ${ROLE:-?} ($( [ "$MODE_NET" = forward ] && echo "forwarding with DNAT: the kernel relays the tunnel" || echo "endpoint: TCP connections end here"))"
  say "  system             $OS, kernel $KV, $(uname -m), $VIRT, $CPUS CPU, $MEM_MIB MiB"
  say "  interface          ${DEV:-?} mtu $(cat /sys/class/net/$DEV/mtu 2>/dev/null) tx queues $(ls -d /sys/class/net/$DEV/queues/tx-* 2>/dev/null | wc -l), qdisc: $(printf '%s ' "${QD[@]%% *}" | tr ' ' '\n' | sort | uniq -c | awk '{printf "%s%s x%s", s, $2, $1; s=", "}')"
  say "  congestion control $CC (available: ${CCAV:-?})"
  local k; for k in net.core.default_qdisc net.ipv4.tcp_slow_start_after_idle net.ipv4.tcp_notsent_lowat net.ipv4.tcp_mtu_probing net.ipv4.tcp_rmem net.ipv4.tcp_wmem; do
    printf '  %-36s %s\n' "${k#net.}" "$(sk "$k" || echo -)"; done
  [ "$CT" = 1 ] && printf '  %-36s %s of %s (be_liberal %s)\n' "conntrack entries" "$CT_CNT" "$CT_MAX" "$(sk net.netfilter.nf_conntrack_tcp_be_liberal || echo -)"
  [ -n "$PORT" ] && printf '  %-18s %s\n' "port $PORT" "$( [ "$LISTEN" = 1 ] && echo "a program listens on it" ||
    { [ "$MODE_NET" = forward ] && echo "forwarded with DNAT" || echo "nothing listens on it here"; })"
  say "  since boot         retransmitted $RETR of $OUTS segments$( [ "$OUTS" -gt 0 ] && awk -v r="$RETR" -v o="$OUTS" 'BEGIN{printf " (%.2f%%)", 100*r/o}'), resets sent $RSTS, memory pressure $PRESS, accept-queue overflow $LOVF, backlog drops $SNDROP"
  sessions
  [ -f "$PERSIST" ] && say "  applied before     $PERSIST ($(grep -c '^[a-z]' "$PERSIST") keys)"
  local last; last=$(latest_backup) && say "  last backup        $last$( [ -e "$last/rolled_back" ] && echo " (rolled back)")"
  return 0
}
report_plan() {
  hdr "plan ($( [ "$MODE" = dry-run ] && echo "dry run: nothing will be changed" || echo "to apply"))"
  local i; if [ ${#PK[@]} -eq 0 ] && [ ${#QREP[@]} -eq 0 ]; then say "  ${G}nothing to change: this host already matches the plan${N}"; fi
  for i in "${!PK[@]}"; do say "  ${B}${PK[$i]}${N}: ${PO[$i]} -> ${G}${PN[$i]}${N}"; say "      why: ${PW[$i]}"; done
  [ ${#QREP[@]} -gt 0 ] && say "  ${B}qdisc of $DEV${N}: $QFROM-> ${G}$QTO${N} ($(printf '%s ' "${QREP[@]%% *}")); kept after reboot by net.core.default_qdisc"
  [ ${#MODS[@]} -gt 0 ] && say "  modules loaded at boot ($MODLOAD): ${MODS[*]}"
  [ ${#SKIP[@]} -gt 0 ] && { hdr "left unchanged"; for i in "${SKIP[@]}"; do say "  - $i"; done; }
  [ ${#NOTE[@]} -gt 0 ] && { hdr "notes"; for i in "${NOTE[@]}"; do say "  - $i"; done; }
  hdr "limits"
  say "  - Host settings cannot make the physical round trip between the two countries shorter than the route allows."
  say "  - BBR does not guarantee more speed or lower delay on every network; the aim is steadier connections and a safe undo."
  say "  - Not touched: iptables/nftables, routes, addresses, MTU, ports, Xray and its config, the tunnel, any service."
  if [ "$MODE" = dry-run ] && { [ ${#PK[@]} -gt 0 ] || [ ${#QREP[@]} -gt 0 ]; }; then
    hdr "to apply"; say "  $SELF --apply --role $ROLE${PORT:+ --port $PORT}"
    say "  Undo later: $SELF --rollback   (or: bash $BKROOT/<time>/rollback.sh)"
  fi
}
latest_backup() { local d; for d in $(ls -1d "$BKROOT"/2* 2>/dev/null | sort -r); do
  [ -f "$d/rollback.sh" ] && [ -e "$d/committed" ] && [ ! -e "$d/rolled_back" ] && { echo "$d"; return 0; }; done; return 1; }

# ---------- apply ----------
BK=; GUARD_UNIT=; GUARD_PID=
write_rollback() {  # rollback.sh restores runtime values, the queues and the two files exactly as saved here
  local i f=$BK/rollback.sh
  { echo '#!/usr/bin/env bash'
    echo "# Generated by net-tune $VERSION on $(date -u +%FT%TZ): restores the state saved in this directory."
    echo 'BK=$(cd "$(dirname "$0")" && pwd); rc=0'
    echo 'w() { sysctl -q -w "$1=$2" >/dev/null 2>&1 || printf "%s" "$2" > "/proc/sys/${1//.//}" 2>/dev/null || { echo "rollback: could not restore $1"; rc=1; }; }'
    for i in "${QREP[@]}"; do set -- $i; [ "$1" = root ] && echo "tc qdisc replace dev $(printf %q "$DEV") root $2 || rc=1" ||
      echo "tc qdisc replace dev $(printf %q "$DEV") parent $1 $2 || rc=1"; done
    for i in "${!PK[@]}"; do printf 'w %q %q\n' "${PK[$i]}" "${PO[$i]}"; done
    for p in "$PERSIST" "$MODLOAD"; do
      echo "if [ -f \"\$BK/files/${p##*/}\" ]; then cp -p \"\$BK/files/${p##*/}\" $(printf %q "$p") || rc=1; else rm -f $(printf %q "$p"); fi"; done
    echo 'touch "$BK/rolled_back"; echo "$(date -u +%FT%TZ) rollback $BK rc=$rc" >> '"$LOG"' 2>/dev/null; exit $rc'
  } > "$f"; chmod 700 "$f"; }
arm_guard() {  # rolls back by itself unless the run reaches 'committed' (e.g. the SSH session dies midway)
  [ "$GUARD" = 0 ] && return 0
  local cmd="[ -e '$BK/committed' ] || [ -e '$BK/rolled_back' ] || bash '$BK/rollback.sh'"
  GUARD_UNIT="hw-net-tune-guard-${BK##*/}"
  # A transient systemd timer runs in the host's namespaces; inside another network namespace use a detached sleeper.
  if command -v systemd-run >/dev/null && [ "$(readlink /proc/self/ns/net)" = "$(readlink /proc/1/ns/net)" ] &&
     systemd-run --quiet --unit "$GUARD_UNIT" --on-active="$GUARD" /bin/bash -c "$cmd" >/dev/null 2>&1; then
    say "  guard: automatic rollback in ${GUARD}s unless this run completes (systemd timer $GUARD_UNIT)"
  else GUARD_UNIT=; setsid bash -c "sleep $GUARD; $cmd" </dev/null >/dev/null 2>&1 9>&- & GUARD_PID=$!   # 9>&-: not the lock
    say "  guard: automatic rollback in ${GUARD}s unless this run completes (background process $GUARD_PID)"; fi; }
disarm_guard() { [ -n "$GUARD_UNIT" ] && systemctl stop "$GUARD_UNIT.timer" >/dev/null 2>&1; [ -n "$GUARD_PID" ] && { kill -- "-$GUARD_PID" 2>/dev/null || kill "$GUARD_PID" 2>/dev/null; }; return 0; }
undo() {  # undo REASON: roll back this run now
  warn "rolling back: $1"; log "apply failed ($1); rolling back $BK"
  if bash "$BK/rollback.sh"; then say "${G}rolled back: the host is as it was before this run${N}"; disarm_guard; exit 3
  else say "${R}rollback reported errors: check the values above; the saved state is in $BK${N}"; disarm_guard; exit 4; fi; }

do_apply() {
  [ ${#PK[@]} -gt 0 ] || [ ${#QREP[@]} -gt 0 ] || { log "apply: nothing to change"; exit 0; }
  if [ "$YES" = 0 ]; then
    tty_ok || die "no terminal to confirm on: run with --yes after reading --dry-run"
    local a; read -r -p "Apply these changes now? Type 'yes': " a </dev/tty || a=
    [ "$a" = yes ] || { say "nothing changed"; exit 0; }
  fi
  exec 9>"$LOCK"; flock -n 9 || die "another net-tune run is in progress"
  trap '' HUP   # a dropped SSH session must not stop the run halfway; the guard covers a stuck run
  # Before: what must not change, measured twice so a ruleset that changes on its own is not blamed on us.
  local fw1 fw2 ns1 ns2 c ok_checks=() auto; fw1=$(fw_hash); ns1=$(net_state); sleep 2; fw2=$(fw_hash); ns2=$(net_state)
  [ "$MODE_NET" = forward ] && [ -n "$PORT" ] && [ ${#DNAT[@]} -eq 1 ] && auto="${DNAT[0]}:$PORT"
  [ "$MODE_NET" = endpoint ] && [ "$LISTEN" = 1 ] && auto="127.0.0.1:$PORT"
  for c in ${auto:-} "${CHECKS[@]}"; do tcp_ok "$c" && ok_checks+=("$c"); done

  # A full disk would leave an empty rollback.sh: refuse unless the backup and the files can really be written.
  local dfree; for c in "$(dirname "$BKROOT")" /etc; do
    dfree=$(df -Pk "$c" 2>/dev/null | awk 'NR==2 {print $4}'); [ "${dfree:-0}" -ge 1024 ] || die "less than 1 MiB free on the filesystem of $c: free some space first; nothing changed"; done
  BK="$BKROOT/$(date -u +%Y%m%dT%H%M%SZ)"; [ -e "$BK" ] && BK="$BK-$$"
  mkdir -p "$BKROOT" && chmod 700 "$BKROOT" && mkdir -m 700 "$BK" "$BK/files" || die "cannot create $BK"
  { echo "version=$VERSION"; echo "role=$ROLE"; echo "mode=$MODE_NET"; echo "kernel=$KV"; echo "dev=$DEV"
    for c in "${!PK[@]}"; do echo "before ${PK[$c]}=${PO[$c]}"; echo "after ${PK[$c]}=${PN[$c]}"; done; } > "$BK/state" || die "cannot write $BK/state; nothing changed"
  [ "$HAVE_TC" = 1 ] && tc qdisc show dev "$DEV" > "$BK/qdisc.before" 2>/dev/null
  for c in "$PERSIST" "$MODLOAD"; do [ -f "$c" ] && { cp -p "$c" "$BK/files/" || die "cannot back up $c; nothing changed"; }; done
  write_rollback
  [ -s "$BK/rollback.sh" ] && bash -n "$BK/rollback.sh" && grep -q 'rolled_back' "$BK/rollback.sh" &&
    [ "$(grep -c '^w ' "$BK/rollback.sh")" = "${#PK[@]}" ] || die "rollback.sh in $BK is incomplete (disk?); nothing changed"
  log "apply start role=$ROLE mode=$MODE_NET backup=$BK keys=${PK[*]} qdisc=${QTO:-none}"
  hdr "applying (runtime first)"; say "  backup: $BK"
  arm_guard
  trap 'undo "interrupted"' INT TERM

  for c in "${MODS[@]}"; do case "$c" in tcp_bbr|sch_fq) modprobe "$c" 2>/dev/null || undo "modprobe $c failed";; esac; done
  for c in "${!PK[@]}"; do
    sysctl -q -w "${PK[$c]}=${PN[$c]}" >/dev/null 2>&1 || printf '%s' "${PN[$c]}" > "$(pk "${PK[$c]}")" 2>/dev/null || undo "cannot set ${PK[$c]}"
    say "  set ${PK[$c]} = ${PN[$c]}"
  done
  for c in "${QREP[@]}"; do set -- $c
    if [ "$1" = root ]; then tc qdisc replace dev "$DEV" root "$QTO" || undo "tc on $DEV failed"
    else tc qdisc replace dev "$DEV" parent "$1" "$QTO" || undo "tc on $DEV parent $1 failed"; fi
  done
  [ ${#QREP[@]} -gt 0 ] && say "  qdisc of $DEV -> $QTO on ${#QREP[@]} queue(s)"

  hdr "checking"
  sleep 5
  for c in "${!PK[@]}"; do [ "$(sk "${PK[$c]}")" = "${PN[$c]}" ] || undo "${PK[$c]} reads back '$(sk "${PK[$c]}")', not '${PN[$c]}'"; done
  say "  values read back: ok"
  if [ ${#QREP[@]} -gt 0 ]; then mapfile -t QD < <(qd_lines); local q
    for q in "${QD[@]}"; do set -- $q; [ "$1" = mq ] || [ "$1" = "$QTO" ] || undo "qdisc of $DEV is $1 after the change"; done; say "  qdisc: ok"; fi
  if [ "$ns1" = "$ns2" ]; then [ "$(net_state)" = "$ns1" ] || undo "routes, addresses or MTU changed during the run"
    say "  default route, addresses, MTU: unchanged"
  else warn "routes or addresses change by themselves on this host (e.g. temporary addresses); not compared"; fi
  if [ "$fw1" = "$fw2" ]; then [ "$(fw_hash)" = "$fw1" ] || undo "the firewall ruleset changed during the run"; say "  firewall ruleset: unchanged"
  else warn "the firewall ruleset changes by itself (dynamic sets); not compared"; fi
  [ "$LISTEN" = 1 ] && { listening || undo "nothing listens on port $PORT any more"; say "  port $PORT: still listening"; }
  for c in "${ok_checks[@]}"; do tcp_ok "$c" || undo "TCP check failed: $( [ "$c" = "${auto:-}" ] && echo "the tunnel port" || echo "$c")"; done
  [ ${#ok_checks[@]} -gt 0 ] && say "  TCP reachability (${#ok_checks[@]} check$( [ ${#ok_checks[@]} -gt 1 ] && echo s)): ok"

  if [ "$YES" = 0 ]; then
    say ""; say "${B}The changes are live. If this SSH session and your services still respond, press Enter within 60 s to keep them.${N}"
    say "Anything else, or no answer, rolls everything back."
    local k; if ! read -r -t 60 k </dev/tty || [ -n "$k" ]; then undo "not confirmed within 60 s"; fi
  fi

  hdr "making it permanent"
  local tmp; tmp=$(mktemp "$PERSIST.XXXXXX") || undo "cannot write $PERSIST"
  { echo "# Written by net-tune $VERSION (HoneyWeb Tunnel), role $ROLE, $(date -u +%FT%TZ)."
    echo "# Undo: net-tune.sh --rollback, or bash $BK/rollback.sh"
    [ -f "$PERSIST" ] && grep -E '^[a-z]' "$PERSIST" | while IFS= read -r l; do k=${l%%=*}; k=${k// /}
      printf '%s\n' "${PK[@]}" | grep -qxF "$k" || echo "$l"; done
    for c in "${!PK[@]}"; do echo "${PK[$c]} = ${PN[$c]}"; done
    # (an if, not &&: the group's status is its last command's, and a false test there would read as a failed write)
    if [ -n "$QTO" ] && ! printf '%s\n' "${PK[@]}" | grep -qx net.core.default_qdisc && [ "$(sk net.core.default_qdisc)" = "$QTO" ] &&
       ! grep -q '^net.core.default_qdisc' "$PERSIST" 2>/dev/null; then echo "net.core.default_qdisc = $QTO"; fi
  } > "$tmp" && chmod 644 "$tmp" && mv -f "$tmp" "$PERSIST" || { rm -f "$tmp"; undo "cannot write $PERSIST"; }
  if [ ${#MODS[@]} -gt 0 ]; then
    { echo "# Written by net-tune $VERSION (HoneyWeb Tunnel): modules needed before $PERSIST is applied at boot"
      { [ -f "$MODLOAD" ] && grep -E '^[a-z]' "$MODLOAD"; printf '%s\n' "${MODS[@]}"; } | sort -u; } > "$MODLOAD.tmp" &&
      mv -f "$MODLOAD.tmp" "$MODLOAD" || undo "cannot write $MODLOAD"
  fi
  sysctl -q -p "$PERSIST" >/dev/null 2>&1 || undo "sysctl rejects $PERSIST"
  for c in "${!PK[@]}"; do [ "$(sk "${PK[$c]}")" = "${PN[$c]}" ] || undo "${PK[$c]} differs after loading $PERSIST"
    local last; last=$(boot_last "${PK[$c]}"); [ -z "$last" ] || [ "$last" = "$PERSIST" ] || warn "at boot $last sets ${PK[$c]} after this file and wins"; done
  say "  $PERSIST$( [ ${#MODS[@]} -gt 0 ] && echo " and $MODLOAD"): written and loaded"
  touch "$BK/committed"; disarm_guard; trap - INT TERM
  log "apply committed $BK"
  hdr "result"
  for c in "${!PK[@]}"; do printf '  %-48s %s -> %s\n' "${PK[$c]}" "${PO[$c]}" "$(sk "${PK[$c]}")"; done
  [ ${#QREP[@]} -gt 0 ] && printf '  %-48s %s-> %s\n' "qdisc $DEV" "$QFROM" "$QTO"
  say "  ${G}done. No service, port, route or firewall rule was touched.${N}"
  say "  Undo: $SELF --rollback   (or: bash $BK/rollback.sh)"
}

do_rollback() {
  local d=${BACKUP:-}; [ -n "$d" ] || d=$(latest_backup) || die "no applied run to roll back in $BKROOT" 1
  [ -f "$d/rollback.sh" ] || die "$d has no rollback.sh"
  [ -e "$d/rolled_back" ] && die "$d was already rolled back"
  hdr "rollback of $d"; grep '^before ' "$d/state" 2>/dev/null | sed 's/^before /  restore /'
  [ -s "$d/qdisc.before" ] && grep -q 'tc qdisc' "$d/rollback.sh" && say "  restore the queues of $(sed -n 's/^dev=//p' "$d/state") to: $(awk '$1=="qdisc" {print $2}' "$d/qdisc.before" | sort -u | tr '\n' ' ')"
  say "  restore $PERSIST and $MODLOAD as they were (or remove them if they did not exist)"
  if [ "$YES" = 0 ]; then tty_ok || die "no terminal to confirm on: run with --yes"
    local a; read -r -p "Roll back now? Type 'yes': " a </dev/tty || a=; [ "$a" = yes ] || { say "nothing changed"; exit 0; }; fi
  exec 9>"$LOCK"; flock -n 9 || die "another net-tune run is in progress"
  log "rollback start $d"
  if bash "$d/rollback.sh"; then
    local bad=0 l k v; while IFS= read -r l; do l=${l#before }; k=${l%%=*}; v=${l#*=}
      [ "$(sk "$k")" = "$v" ] || { warn "$k is $(sk "$k"), expected $v"; bad=1; }; done < <(grep '^before ' "$d/state")
    [ "$bad" = 0 ] && say "${G}rolled back: values read back as they were before that run${N}" || exit 4
  else die "rollback.sh reported errors (see above)" 4; fi
}

# ---------- main ----------
if [ "$MODE" = rollback ]; then do_rollback; exit $?; fi
if [ -z "$ROLE" ]; then
  if [ "$MODE" = status ]; then ROLE=finland; [ "$(sk net.ipv4.ip_forward)" = 1 ] && [ -n "$(dnat_dests)" ] && ROLE=iran
  elif tty_ok; then read -r -p "Which server is this? [iran/finland]: " ROLE </dev/tty || ROLE=
    case "$ROLE" in iran|finland) ;; *) die "answer iran or finland" 2;; esac
  else die "--role iran|finland is required" 2; fi
fi
if [ -z "$PORT" ] && [ "$MODE" != status ] && [ "$YES" = 0 ] && tty_ok; then
  read -r -p "TCP port of the inbound on this tunnel (Enter to skip): " PORT </dev/tty || PORT=
  [ -z "$PORT" ] || [[ "$PORT" =~ ^[0-9]+$ ]] || die "port must be a number" 2
fi
facts; build_plan; svc_nofile
say "${B}net-tune $VERSION${N} - $MODE"
report_host
[ "$MODE" = status ] && { [ ${#NOTE[@]} -gt 0 ] && { hdr "notes"; for n in "${NOTE[@]}"; do say "  - $n"; done; }; exit 0; }
report_plan
[ "$MODE" = apply ] && do_apply
exit 0
