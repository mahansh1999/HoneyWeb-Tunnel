#!/usr/bin/env bash
# HoneyWeb Tunnel Manager: list, inspect, edit and remove the tunnels HoneyWeb installed on THIS server.
# Run as root. Without arguments it opens the interactive menu.
#
#   manage.sh list                              every HoneyWeb tunnel here, one line each
#   manage.sh show NAME                         everything about one tunnel (id, ports, pool, service, sessions, errors)
#   manage.sh ports NAME list                   port mappings (Iran/server side only: the far end gets the target
#   manage.sh ports NAME add MAP                per connection from here, so mappings are never edited abroad)
#   manage.sh ports NAME del LISTEN_PORT        MAP = PORT | PORT=TARGET_PORT | PORT=HOST:PORT | IP:PORT=...
#   manage.sh ports NAME set MAP[,MAP...]
#   manage.sh ports NAME move OLD NEW           a user port listens on NEW instead of OLD, same target (live: OLD's
#                                               open connections stay until they end)
#   manage.sh tunnel-port NAME PORT             the tunnel's own port, on BOTH servers (Iran side, needs peer-setup;
#                                               --one-side: this server only). Sessions are cut for a few seconds;
#                                               if the tunnel does not come back, both sides return to the old port
#   manage.sh set-remote NAME IP [--keep]       foreign side: the Iran server has a new IP (tunnel port unchanged)
#   manage.sh set-allow NAME IP                 Iran side: the foreign server has a new IP (tunnel firewall only)
#   manage.sh pool NAME N [--allow-decrease]    connection_pool (foreign/client side)
#   manage.sh profile NAME turbo|default        performance keys only; capacity is never touched
#   manage.sh restart NAME                      restart only this tunnel's service
#   manage.sh backups NAME | restore NAME TXID  configs saved before every change
#   manage.sh remove NAME --confirm NAME        this server's side only; the other side is reported, not touched
#   manage.sh version NAME                      config version (hash of its content), engine, tunnel id
#   Two-sided (after `peer-setup` on both servers; the agent goes through the tunnel itself, loopback only):
#   manage.sh peer-setup NAME                   install the management agent here (Iran: also its hidden mapping)
#   manage.sh peer NAME CMD ARGS...             run a manage.sh command on the OTHER server of this tunnel
#   manage.sh status-both NAME                  both sides: service, sessions, config version, same tunnel id?
#   manage.sh remove-both NAME --confirm NAME   the other side first (scheduled, it cuts the channel), then here
#   Make-before-break (Iran side; from abroad: manage.sh peer NAME migrate ... --background):
#   manage.sh migrate NAME --transport T --tunnel-port P [--new-name N] [--drain SEC] [--background]
#   manage.sh migrate-status TXID | migrate-resume TXID | migrate-abort TXID | migrate-list
#   Add --yes to skip the confirmation (the impact is still printed).
#
# Every change is one transaction: lock -> backup (TXID) -> new file checked by `hwtunnel check` -> impact (active
# connections) -> confirm -> atomic replace -> health check -> automatic rollback if unhealthy. Results go to
# /opt/hwtunnel/etc/manage.log. Only /opt/hwtunnel/etc/NAME.* and the hwtunnel-NAME units are ever touched:
# Xray, PasarGuard, Docker, nginx and any other service are not looked at or changed.
# Today the engine restarts a tunnel's generation on any config change: active connections of THAT tunnel are cut
# for about 2 s (other tunnels are not affected). The impact line says so before you confirm.
set -euo pipefail
ROOT=/opt/hwtunnel; ETC=$ROOT/etc; BIN=$ROOT/bin/hwtunnel; BK=$ETC/backups; LOG=$ETC/manage.log
YES=0; ARGS=(); for a in "$@"; do case "$a" in --yes|-y) YES=1;; --test-fail-health) export HWT_MANAGE_FAIL_HEALTH=1;; *) ARGS+=("$a");; esac; done; set -- "${ARGS[@]+"${ARGS[@]}"}"
c() { [ -t 1 ] && printf '\033[%sm%s\033[0m' "$1" "$2" || printf '%s' "$2"; }
die() { echo "$(c 31 manage.sh:) $*" >&2; exit 1; }
say() { echo "==> $*"; }
[ "$(id -u)" = 0 ] || die "run as root"
[ -d "$ETC" ] || die "no HoneyWeb Tunnel installation here ($ETC missing)"

# ---- reading a tunnel -------------------------------------------------------------------------------------------
tunnels() { local f n; for f in "$ETC"/*.toml; do [ -f "$f" ] || continue; n=$(basename "$f" .toml)
  [ -f "/etc/systemd/system/hwtunnel-$n.service" ] && echo "$n"; done; }
cfg() { echo "$ETC/$1.toml"; }
exists() { [[ "$1" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ -f "$(cfg "$1")" ] && [ -f "/etc/systemd/system/hwtunnel-$1.service" ] || die "no HoneyWeb tunnel named '$1' (see: manage.sh list)"; }
get() { sed -nE "s/^$2[[:space:]]*=[[:space:]]*\"?([^\"]*)\"?[[:space:]]*$/\1/p" "$(cfg "$1")" | head -1; }
role() { grep -q '^\[server\]' "$(cfg "$1")" && echo server || echo client; }
tid() { local t; t=$(get "$1" token); [ -n "$t" ] && printf '%s' "$t" | sha256sum | cut -c1-12 || echo none; }
plist() { sed -nE 's/^ports[[:space:]]*=[[:space:]]*\[(.*)\][[:space:]]*$/\1/p' "$(cfg "$1")" | tr -d '" ' | tr ',' '\n' | grep . || true; }
lport() { local m=${1%%=*}; echo "${m##*:}"; }
tport() { if [ "$(role "$1")" = server ]; then get "$1" bind_addr | sed 's/.*://'; else get "$1" remote_addr | sed 's/.*://'; fi; }
family() { case "$1" in tcpmux|wsmux|wssmux) echo mux;; tcp|ws|wss|stealth) echo tcp;; kcp|quic) echo udp;; *) echo other;; esac; }
sessions() { local p; p=$(tport "$1"); if [ "$(role "$1")" = server ]; then ss -Htn state established "( sport = :$p )" | wc -l
  else ss -Htn state established "( dport = :$p )" | wc -l; fi; }
users() { local n=0 m p; [ "$(role "$1")" = server ] || { echo -; return; }
  for m in $(plist "$1"); do p=$(lport "$m"); n=$((n + $(ss -Htn state established "( sport = :$p )" | wc -l))); done; echo $n; }
profile_of() { [ "$(get "$1" mux_recievebuffer)" = 16777216 ] && echo turbo || { [ "$(family "$(get "$1" transport)")" = mux ] && echo default || echo n/a; }; }
uptime_of() { local t; t=$(systemctl show -p ActiveEnterTimestamp --value "hwtunnel-$1"); [ -n "$t" ] && echo "$(( $(date +%s) - $(date -d "$t" +%s) ))s" || echo -; }
lasterr() { journalctl -u "hwtunnel-$1" -p err -n 1 --no-pager -o cat 2>/dev/null | cut -c1-120 | sed -E 's/([0-9]{1,3}\.){3}[0-9]{1,3}/x.x.x.x/g'; }
in_use_by_other() { local p=$1 n=$2 own pids; own=$(plist "$n" | while read -r m; do lport "$m"; done | grep -qx "$p" && echo y || echo n)
  [ "$own" = y ] && return 1
  # during a migration the new tunnel may take the ports the old one (HWT_HANDOVER_PID) still holds
  if [ -n "${HWT_HANDOVER_PID:-}" ]; then pids=$(ss -Htlnp "( sport = :$p )" | grep -o 'pid=[0-9]*' | sort -u | tr '\n' ' ')
    [ -z "$pids" ] || [ "$pids" = "pid=$HWT_HANDOVER_PID " ] && return 1; fi
  ss -Htln "( sport = :$p )" | grep -q .; }

# ---- transactions -----------------------------------------------------------------------------------------------
TX=""; LOCKFD=""
begin() { exec {LOCKFD}>/run/hwtunnel-manage.lock; flock -n "$LOCKFD" || die "another manage.sh change is running"
  TX=$(date -u +%Y%m%dT%H%M%SZ)-$$; install -d -m 0700 "$BK"
  cp -p "$(cfg "$1")" "$BK/$1.$TX.toml"; cp -p "/etc/systemd/system/hwtunnel-$1.service" "$BK/$1.$TX.service"; }
logtx() { printf '%s tx=%s name=%s op=%s result=%s\n' "$(date -u +%FT%TZ)" "$TX" "$1" "$2" "$3" >> "$LOG"; }
confirm() { echo "$(c 33 impact:) $1"; [ $YES = 1 ] && return 0; [ -t 0 ] || die "not confirmed (add --yes to apply without a terminal)"
  local r; read -r -p "Apply? (y/n) " r; [[ "$r" =~ ^[Yy] ]] || { say "nothing changed"; logtx "$NAME" "$OP" aborted; exit 0; }; }
healthy() { local n=$1 before=$2 i need m p ok
  # EXPECT (set by a pool change) is the session count the new config should reach; otherwise the count before.
  # HEALTH_SECS: how long to wait (a two-sided tunnel-port change waits for the other side to switch too).
  [ -n "${EXPECT:-}" ] && before=$EXPECT
  need=$(( before * 9 / 10 )); [ "$need" -lt 1 ] && need=1
  for i in $(seq 1 "${HEALTH_SECS:-30}"); do sleep 1
    systemctl is-active --quiet "hwtunnel-$n" || continue
    ok=1
    if [ "$(role "$n")" = server ]; then
      # the engine opens the user ports once the first sessions pair: with none before and none now (the foreign
      # side not connected yet, as during installation) there is nothing more to check than the running service
      if [ "$before" -gt 0 ] || [ "$(sessions "$n")" -gt 0 ]; then
        for m in $(plist "$n"); do p=$(lport "$m"); ss -Htlnp "( sport = :$p )" | grep -q hwtunnel || ok=0; done; fi
      [ "$before" -gt 0 ] && [ "$(sessions "$n")" -lt "$need" ] && ok=0
    else [ "$(sessions "$n")" -lt "$need" ] && ok=0; fi
    [ "${HWT_MANAGE_FAIL_HEALTH:-0}" = 1 ] && ok=0   # tests only: force the rollback path
    [ $ok = 1 ] && return 0
  done; return 1; }
# apply NAME NEWFILE MODE(reload|restart) DESCRIPTION [live]
# "live": an engine with zero-downtime reloads (HoneyWeb engine, cmd/live.go) takes this change without restarting
# the tunnel; the engine log then says "applied without a restart". An older engine restarts it instead.
apply() { local n=$1 new=$2 mode=$3 what=$4 lv=${5:-} before u since how
  chown root:hwtunnel "$new"; chmod 0640 "$new"
  "$BIN" check -c "$new" >/dev/null 2>&1 || { "$BIN" check -c "$new" 2>&1 | tail -3; rm -f "$new"; logtx "$n" "$OP" invalid; die "the new config failed hwtunnel check; nothing changed"; }
  before=$(sessions "$n"); u=$(users "$n")
  if [ "$mode" = reload ] && [ "$lv" = live ]; then
    confirm "$what. Tunnel $n has $before tunnel sessions and $u active user connections. A zero-downtime engine applies this live and cuts none of them; an older engine reloads the tunnel and cuts them for about 2-5 s. Other tunnels are not affected."
  else
    confirm "$what. Tunnel $n has $before tunnel sessions and $u active user connections; they are cut for about 2-5 s while it $([ "$mode" = restart ] && echo restarts || echo reloads). Other tunnels are not affected."
  fi
  since=$(date '+%Y-%m-%d %H:%M:%S')
  mv "$new" "$(cfg "$n")"
  [ "$mode" = restart ] && { systemctl daemon-reload; systemctl restart "hwtunnel-$n"; }
  if healthy "$n" "$before"; then
    how="restarted"; [ "$mode" = reload ] && how="reloaded (generation restarted)"
    if [ "$mode" = reload ]; then local i; for i in 1 2 3 4 5 6; do
      journalctl -u "hwtunnel-$n" --since "$since" --no-pager -o cat 2>/dev/null | grep -q "applied without a restart" && { how="applied live, no restart: open connections kept"; break; }
      journalctl -u "hwtunnel-$n" --since "$since" --no-pager -o cat 2>/dev/null | grep -q "restarting the tunnel" && break; sleep 1; done; fi
    say "applied (tx $TX): $how; sessions $(sessions "$n"), service $(systemctl is-active "hwtunnel-$n")"; logtx "$n" "$OP" "ok:${how%%:*}"; return 0; fi
  if [ "${KEEP:-0}" = 1 ]; then logtx "$n" "$OP" kept-unhealthy
    die "the change is kept (--keep) but tunnel $n is not connected yet ($(sessions "$n") sessions): check the other server; undo with: manage.sh restore $n $TX"; fi
  echo "$(c 31 '!!') unhealthy after the change; rolling back to tx $TX"
  if [ "$mode" = reload ] && [ "$lv" = live ] && cmp -s "$BK/$n.$TX.service" "/etc/systemd/system/hwtunnel-$n.service"; then
    # the previous file goes back the same way the change came: live on a zero-downtime engine, no restart forced
    cp -p "$BK/$n.$TX.toml" "$(cfg "$n").rb-$TX" && mv "$(cfg "$n").rb-$TX" "$(cfg "$n")"
  else
    cp -p "$BK/$n.$TX.toml" "$(cfg "$n")"; cp -p "$BK/$n.$TX.service" "/etc/systemd/system/hwtunnel-$n.service"
    systemctl daemon-reload; systemctl restart "hwtunnel-$n"
  fi
  if HWT_MANAGE_FAIL_HEALTH=0 healthy "$n" "$before"; then logtx "$n" "$OP" rolled-back; die "change rolled back; the tunnel runs the previous config again"
  else logtx "$n" "$OP" rollback-unhealthy; die "rolled back, but the tunnel is still unhealthy: journalctl -u hwtunnel-$n"; fi; }

# ---- two-sided management (internal/peer; docs/manage/manage-tunnel.md) ----------------------------------------
AGENT=127.0.0.1:59111
peerport() { sed -n 's/^port=//p' "$ETC/$1.peer" 2>/dev/null | head -1; }
is_mgmt() { [[ "$1" =~ ^127\.0\.0\.1:59[2-9][0-9][0-9]=127\.0\.0\.1:59111$ ]]; }
cfgver() { grep -vE '^[[:space:]]*(#|$)' "$(cfg "$1")" | sha256sum | cut -c1-12; }
# ssh_guard NAME: refuse when the SSH session running this command comes in through this tunnel itself
ssh_guard() { local n=$1 lp m; [ -n "${SSH_CONNECTION:-}" ] || return 0; [ "${HWT_SSH_OK:-0}" = 1 ] && return 0
  lp=$(echo "$SSH_CONNECTION" | awk '{print $4}')
  if [ "$(role "$n")" = server ]; then
    for m in $(plist "$n"); do [ "$(lport "$m")" = "$lp" ] && die "your SSH session comes in through port $lp of tunnel $n; changing or removing it would cut you off. Use another path (or HWT_SSH_OK=1 if you have one)"; done
  else
    case "$(echo "$SSH_CONNECTION" | awk '{print $1}')" in 127.0.0.1|::1) die "your SSH session comes from loopback, probably through a tunnel to this server; make sure it is not tunnel $n (HWT_SSH_OK=1 to go on)";; esac
  fi; return 0; }

# ---- views ------------------------------------------------------------------------------------------------------
cmd_list() { local n any=0
  printf '%-14s %-12s %-7s %-8s %-7s %-22s %-6s %-9s %s\n' NAME ID ROLE TRANSP PROFILE PORTS POOL SESSIONS SERVICE
  for n in $(tunnels); do any=1
    printf '%-14s %-12s %-7s %-8s %-7s %-22s %-6s %-9s %s\n' "$n" "$(tid "$n")" "$(role "$n")" "$(get "$n" transport)" "$(profile_of "$n")" \
      "$( [ "$(role "$n")" = server ] && plist "$n" | paste -sd, | cut -c1-22 || echo "->:$(tport "$n")")" "$(v=$(get "$n" connection_pool || true); echo "${v:--}")" \
      "$(sessions "$n")" "$(systemctl is-active "hwtunnel-$n" 2>/dev/null || true)"
  done; [ $any = 1 ] || echo "(no HoneyWeb tunnels on this server)"; }
cmd_show() { local n=$1 r; exists "$n"; r=$(role "$n")
  echo "name         $n"; echo "id           $(tid "$n")  (same on both servers of one tunnel; derived from the token, which is not shown)"
  echo "role         $r ($([ "$r" = server ] && echo 'Iran / entry' || echo 'foreign / exit'))"
  echo "transport    $(get "$n" transport)   profile $(profile_of "$n")"
  if [ "$r" = server ]; then echo "tunnel port  $(get "$n" bind_addr)   mux_con $(get "$n" mux_con)"; echo "port maps    $(plist "$n" | paste -sd' ')"
  else echo "server       $(get "$n" remote_addr | sed -E 's/^([0-9]{1,3}\.){3}[0-9]{1,3}/&/')   connection_pool $(get "$n" connection_pool)"; fi
  echo "service      $(systemctl is-active "hwtunnel-$n") restarts=$(systemctl show -p NRestarts --value "hwtunnel-$n") uptime=$(uptime_of "$n")"
  echo "sessions     $(sessions "$n")   active user connections $(users "$n")"
  echo "binary       $(readlink "$BIN") ($("$BIN" -v 2>&1 | head -1))"
  echo "last error   $(lasterr "$n" || true)"
  echo "firewall     $([ -f "/etc/systemd/system/hwtunnel-$n-firewall.service" ] && systemctl is-active "hwtunnel-$n-firewall" || echo none)"; }

# ---- edits ------------------------------------------------------------------------------------------------------
validmap() { [[ "$1" =~ ^([0-9.]+:)?[0-9]{1,5}(-[0-9]{1,5})?(=([0-9A-Za-z.-]+:)?[0-9]{1,5}(-[0-9]{1,5})?)?$ ]]; }
# mvmap MAP PORT: the same mapping listening on PORT (its IP and its target kept; "540" -> "PORT=540")
mvmap() { local l=${1%%=*} t; if [[ "$1" == *=* ]]; then t=${1#*=}; else t=$(lport "$1"); fi
  if [[ "$l" == *:* ]]; then echo "${l%:*}:$2=$t"; else echo "$2=$t"; fi; }
cmd_ports() { local n=$1 sub=${2:-list} arg=${3:-} arg2=${4:-} cur new m p seen="" caps=0 lost=""
  exists "$n"; [ "$(role "$n")" = server ] || die "port mappings live on the Iran (server) side only; run this there"
  [ "$sub" = list ] && { for m in $(plist "$n"); do p=$(lport "$m"); echo "  $m   listening=$(ss -Htlnp "( sport = :$p )" | grep -q hwtunnel && echo yes || echo NO) users=$(ss -Htn state established "( sport = :$p )" | wc -l)"; done; return; }
  cur=$(plist "$n" | paste -sd,)
  local mg; mg=$(plist "$n" | while read -r m; do if is_mgmt "$m"; then echo "$m"; fi; done | paste -sd,)
  ssh_guard "$n"
  case "$sub" in
    add) validmap "$arg" || die "bad mapping '$arg'"; new="$cur,$arg";;
    del) [[ "$arg" =~ ^[0-9]+$ ]] || die "del takes the listening port"; new=$(plist "$n" | while read -r m; do [ "$(lport "$m")" = "$arg" ] || echo "$m"; done | paste -sd,)
         [ "$new" != "$cur" ] || die "no mapping listens on $arg";;
    set) new=$arg;;
    move) [[ "$arg" =~ ^[0-9]+$ && "$arg2" =~ ^[0-9]+$ ]] || die "move takes OLD_PORT NEW_PORT"
          new=$(plist "$n" | while read -r m; do if [ "$(lport "$m")" = "$arg" ] && ! is_mgmt "$m"; then mvmap "$m" "$arg2"; else echo "$m"; fi; done | paste -sd,)
          [ "$new" != "$cur" ] || die "no user mapping listens on $arg";;
    *) die "ports NAME list|add MAP|del PORT|move OLD NEW|set MAP[,MAP...]";;
  esac
  new=${new#,}
  # the hidden management mapping stays, whatever the user edits (set, del)
  if [ -n "$mg" ] && [[ ",$new," != *",$mg,"* ]]; then
    [ "$sub" = del ] && [ "$(lport "$mg")" = "$arg" ] && die "port $arg is the management mapping (manage.sh peer-setup); it is not a user port"
    new="$new,$mg"
  fi
  new=${new#,}; [ -n "$new" ] || die "a server tunnel needs at least one mapping"
  for m in ${new//,/ }; do validmap "$m" || die "bad mapping '$m'"; p=$(lport "$m")
    [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "bad port $p"
    [[ " $seen " == *" $p "* ]] && die "port $p is listed twice"; seen="$seen $p"
    [ "$p" = "$(tport "$n")" ] && [ "$(family "$(get "$n" transport)")" != udp ] && die "$p is this tunnel's own tunnel port"
    in_use_by_other "$p" "$n" && die "port $p is already used by another program: $(ss -Htlnp "( sport = :$p )" | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | head -1)"
    [ "$p" -lt 1024 ] && caps=1
  done
  for m in $(plist "$n"); do p=$(lport "$m"); [[ " $seen " == *" $p "* ]] || lost="$lost $p"; done
  NAME=$n; OP="ports:$new"; begin "$n"
  local f; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  local q; q=$(printf '"%s", ' ${new//,/ }); sed -i -E "s|^ports[[:space:]]*=.*|ports = [${q%, }]|" "$f"
  local mode=reload
  if [ $caps = 1 ] && ! grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE' "/etc/systemd/system/hwtunnel-$n.service"; then
    sed -i -E 's/^CapabilityBoundingSet=.*/CapabilityBoundingSet=CAP_NET_BIND_SERVICE/; s/^AmbientCapabilities=.*/AmbientCapabilities=CAP_NET_BIND_SERVICE/' "/etc/systemd/system/hwtunnel-$n.service"; mode=restart; fi
  [ -n "$lost" ] && echo "$(c 33 warning:) port(s)$lost will stop listening: connections open on them stay until they end, but clients configured for them will no longer connect"
  apply "$n" "$f" "$mode" "ports $(echo "$cur" | tr , ' ') -> $(echo "$new" | tr , ' ')" live; }
cmd_pool() { local n=$1 v=${2:-} dec=${3:-} cur f
  exists "$n"; [ "$(role "$n")" = client ] || die "connection_pool is set on the foreign (client) side; run this there"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 8 ] && [ "$v" -le 8192 ] || die "pool must be 8..8192"
  cur=$(get "$n" connection_pool); cur=${cur:-8}
  [ "$v" = "$cur" ] && { say "connection_pool is already $v"; return; }
  [ "$v" -lt "$cur" ] && [ "$dec" != --allow-decrease ] && die "lowering the pool $cur -> $v lowers capacity (the 2026-10-31 saturation came from too small a pool); add --allow-decrease if you mean it"
  NAME=$n; OP="pool:$cur->$v"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  if grep -q '^connection_pool' "$f"; then sed -i -E "s/^connection_pool[[:space:]]*=.*/connection_pool = $v/" "$f"; else sed -i "/^\[client\]/a connection_pool = $v" "$f"; fi
  EXPECT=$(( v + 1 ))   # pool sessions + the control channel
  local lv=""; [ "$v" -gt "$cur" ] && lv=live   # a raise is live on a zero-downtime engine; a decrease restarts
  apply "$n" "$f" reload "connection_pool $cur -> $v ($((v * 8)) streams at mux_con 8)" "$lv"; }
cmd_profile() { local n=$1 p=${2:-} f t
  exists "$n"; t=$(get "$n" transport); [ "$(family "$t")" = mux ] || die "profiles apply to tcpmux, wsmux and wssmux"
  case "$p" in turbo|default) ;; *) die "profile NAME turbo|default";; esac
  [ "$(profile_of "$n")" = "$p" ] && { say "already $p"; return; }
  NAME=$n; OP="profile:$p"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  sed -i -E '/^(mux_streambuffer|mux_recievebuffer)[[:space:]]*=/d' "$f"
  if [ "$p" = turbo ]; then sed -i "/^\[\(server\|client\)\]/a mux_recievebuffer = 16777216" "$f"; sed -i "/^\[\(server\|client\)\]/a mux_streambuffer = 2097152" "$f"; fi
  grep -q '^nodelay' "$f" || sed -i "/^\[\(server\|client\)\]/a nodelay = true" "$f"
  echo "note: set the same profile on the other server of this tunnel (id $(tid "$n")); capacity keys are not changed"
  apply "$n" "$f" reload "profile $(profile_of "$n") -> $p (connection_pool and mux_con unchanged)"; }
cmd_restart() { local n=$1 before; exists "$n"; NAME=$n; OP=restart; begin "$n"; before=$(sessions "$n")
  confirm "restart hwtunnel-$n: $before sessions and $(users "$n") user connections are cut for a few seconds"
  systemctl restart "hwtunnel-$n"; healthy "$n" "$before" && { say "restarted, sessions $(sessions "$n")"; logtx "$n" restart ok; } || { logtx "$n" restart unhealthy; die "restarted but unhealthy: journalctl -u hwtunnel-$n"; }; }
cmd_backups() { exists "$1"; ls -1 "$BK" 2>/dev/null | sed -nE "s/^$1\.(.*)\.toml$/  \1/p"; grep " name=$1 " "$LOG" 2>/dev/null | tail -10 | sed 's/^/  log: /' || true; }
cmd_restore() { local n=$1 t=${2:-} f; exists "$n"; [ -f "$BK/$n.$t.toml" ] || die "no backup $t for $n (see: manage.sh backups $n)"
  NAME=$n; OP="restore:$t"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$BK/$n.$t.toml" "$f"
  local mode=reload; cmp -s "$BK/$n.$t.service" "/etc/systemd/system/hwtunnel-$n.service" || { cp -p "$BK/$n.$t.service" "/etc/systemd/system/hwtunnel-$n.service"; mode=restart; }
  apply "$n" "$f" "$mode" "restore the config saved in tx $t"; }
cmd_remove() { local n=$1 conf=${2:-} name=${3:-} dflag=${4:-} delay=${5:-} d
  exists "$n"; [ "$conf" = --confirm ] && [ "$name" = "$n" ] || die "type the name to confirm: manage.sh remove $n --confirm $n"
  ssh_guard "$n"
  if [ "$dflag" = --delay ]; then
    [[ "$delay" =~ ^[0-9]{1,3}$ ]] || die "--delay takes seconds"
    [ -f "$ROOT/bin/manage.sh" ] || die "$ROOT/bin/manage.sh is missing (manage.sh peer-setup installs it)"
    systemd-run --quiet --on-active="${delay}s" --unit="hwt-remove-$n-$$" --collect /bin/bash "$ROOT/bin/manage.sh" remove "$n" --confirm "$n" --yes \
      || die "could not schedule the removal"
    TX=$(date -u +%Y%m%dT%H%M%SZ)-$$; logtx "$n" remove "scheduled:${delay}s"
    say "removal of $n scheduled in ${delay} s (unit hwt-remove-$n-$$): its $(sessions "$n") sessions end then"; return 0
  fi
  NAME=$n; OP=remove; begin "$n"
  confirm "remove tunnel $n (id $(tid "$n")) from THIS server: $(sessions "$n") sessions and $(users "$n") user connections end now. Its other side keeps running until removed there (manage.sh remove $n there). Binary, other tunnels and other services stay"
  systemctl disable --now "hwtunnel-$n" >/dev/null 2>&1 || true
  systemctl disable --now "hwtunnel-$n-firewall" >/dev/null 2>&1 || true
  d="$ETC/removed/$n.$TX"; install -d -m 0700 "$d"
  for f in "$ETC/$n".*; do [ -e "$f" ] && mv "$f" "$d/"; done
  mv "/etc/systemd/system/hwtunnel-$n.service" "$d/" 2>/dev/null || true; mv "/etc/systemd/system/hwtunnel-$n-firewall.service" "$d/" 2>/dev/null || true
  systemctl daemon-reload; logtx "$n" remove ok
  say "removed from this server; files kept in $d. Other side: still installed (remove it there; it reconnects in vain until then)"; }

# ---- addresses: the tunnel port and the servers' IPs ------------------------------------------------------------
validip() { local o; [[ "$1" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || return 1; for o in ${1//./ }; do [ "$o" -le 255 ] || return 1; done; }
validhost() { if [[ "$1" =~ ^[0-9.]+$ ]]; then validip "$1"; else [[ "$1" =~ ^[A-Za-z0-9]([A-Za-z0-9.-]{0,251}[A-Za-z0-9])?$ ]]; fi; }
# tunnel-port NAME PORT [--one-side] [--delay S]
#  Iran (server): the other server is told first, through the tunnel, to switch S s later (default 4); then this
#  side moves. Each side waits for at least one tunnel session on the new port and returns to the old port by
#  itself if none comes (foreign after 30 s, Iran after S+50 s), so both end on the new port or both on the old.
#  The tunnel's firewall rule (if any) moves with the port.
#  Foreign (client): --delay S schedules the switch (that is how Iran asks for it); without it, the switch is now.
cmd_tunnel_port() { local n=$1 p=${2:-} one=0 delay="" old f out fw="" b rc=0 hs
  shift 2 || shift $#
  while [ $# -gt 0 ]; do case "$1" in --one-side) one=1; shift;; --delay) delay=${2:-}; shift 2 || shift;; *) die "tunnel-port: unknown $1";; esac; done
  exists "$n"; [[ "$p" =~ ^[0-9]+$ ]] && [ "$p" -ge 1 ] && [ "$p" -le 65535 ] || die "bad port '$p'"
  [ -z "$delay" ] || [[ "$delay" =~ ^[0-9]{1,3}$ ]] || die "--delay takes seconds"
  old=$(tport "$n"); [ "$p" = "$old" ] && { say "tunnel $n already uses port $p"; return 0; }
  ssh_guard "$n"
  if [ "$(role "$n")" = client ]; then
    if [ -n "$delay" ]; then
      [ -f "$ROOT/bin/manage.sh" ] || die "$ROOT/bin/manage.sh is missing (manage.sh peer-setup installs it)"
      systemd-run --quiet --on-active="${delay}s" --unit="hwt-tport-$n-$$" --collect /bin/bash "$ROOT/bin/manage.sh" tunnel-port "$n" "$p" --yes \
        || die "could not schedule the switch"
      TX=$(date -u +%Y%m%dT%H%M%SZ)-$$; logtx "$n" "tunnel-port:$old->$p" "scheduled:${delay}s"
      say "tunnel port $old -> $p scheduled in $delay s (unit hwt-tport-$n-$$); back to $old by itself if no session comes on $p"; return 0
    fi
    NAME=$n; OP="tunnel-port:$old->$p"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
    b=$(get "$n" remote_addr); setkey "$f" remote_addr "\"${b%:*}:$p\""
    [ $one = 1 ] && KEEP=1
    EXPECT=1 apply "$n" "$f" restart "tunnel $n connects to port $p instead of $old of the Iran server (which must listen on $p)"; return
  fi
  ss -Htuln "( sport = :$p )" | grep -q . && die "port $p is in use here: $(ss -Htulnp "( sport = :$p )" | grep -o 'users:(("[^"]*"' | cut -d'"' -f2 | head -1)"
  for m in $(plist "$n"); do [ "$(lport "$m")" = "$p" ] && die "port $p is a user port of tunnel $n"; done
  if [ $one = 0 ]; then
    [ -n "$(peerport "$n")" ] || die "tunnel $n has no management channel to switch the other server with: run manage.sh peer-setup $n on both servers, or use --one-side here and 'manage.sh tunnel-port $n $p --one-side' on the other server"
    out=$(cmd_peer "$n" version "$n" 2>&1) || die "the other server is not reachable through $n ($out): nothing changed"
  fi
  NAME=$n; OP="tunnel-port:$old->$p"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  b=$(get "$n" bind_addr); setkey "$f" bind_addr "\"${b%:*}:$p\""
  "$BIN" check -c "$f" >/dev/null 2>&1 || { "$BIN" check -c "$f" 2>&1 | tail -3; rm -f "$f"; logtx "$n" "$OP" invalid; die "the new config failed hwtunnel check; nothing changed"; }
  if [ -f "$ETC/$n.nft" ]; then cp -p "$ETC/$n.nft" "$BK/$n.$TX.nft"; fw="$ETC/$n.nft.new-$TX"
    sed -E "s/dport $old( |$)/dport $p\1/g" "$ETC/$n.nft" > "$fw"
    nft -c -f "$fw" || { rm -f "$fw" "$f"; logtx "$n" "$OP" invalid; die "the firewall rule for port $p failed validation; nothing changed"; }; fi
  delay=${delay:-4}
  confirm "tunnel $n moves from port $old to $p $([ $one = 0 ] && echo "on both servers (the other one switches $delay s after this one)" || echo "on THIS server only (switch the other server yourself)"): its $(sessions "$n") sessions and $(users "$n") user connections are cut for about $((delay + 5)) s$([ -n "$fw" ] && echo "; the tunnel firewall rule moves to $p")"
  if [ $one = 0 ]; then
    out=$(cmd_peer "$n" tunnel-port "$n" "$p" --delay "$delay" 2>&1) && [[ "$out" == *scheduled* ]] \
      || { rm -f "$f" ${fw:+"$fw"}; echo "$out"; logtx "$n" "$OP" "peer-refused"; die "the other server did not schedule the switch: nothing changed"; }
    echo "   other server: $(echo "$out" | tail -1)"
  fi
  if [ -n "$fw" ]; then mv "$fw" "$ETC/$n.nft"; nft -f "$ETC/$n.nft"
    sed -i "s/tunnel port $old only/tunnel port $p only/" "/etc/systemd/system/hwtunnel-$n-firewall.service"; fi
  if [ "$p" -lt 1024 ] && ! grep -q '^AmbientCapabilities=CAP_NET_BIND_SERVICE' "/etc/systemd/system/hwtunnel-$n.service"; then
    sed -i -E 's/^CapabilityBoundingSet=.*/CapabilityBoundingSet=CAP_NET_BIND_SERVICE/; s/^AmbientCapabilities=.*/AmbientCapabilities=CAP_NET_BIND_SERVICE/' "/etc/systemd/system/hwtunnel-$n.service"; fi
  hs=30; [ $one = 0 ] && hs=$((delay + 50))
  # healthy = the user ports listen and at least one session came on the new port (the same test the other side uses)
  (YES=1; KEEP=$one; EXPECT=1; HEALTH_SECS=$hs; apply "$n" "$f" restart "tunnel port $old -> $p") || rc=$?
  if [ $rc != 0 ] && [ $one = 0 ]; then
    if [ -n "$fw" ]; then cp -p "$BK/$n.$TX.nft" "$ETC/$n.nft"; nft -f "$ETC/$n.nft" || true
      sed -i "s/tunnel port $p only/tunnel port $old only/" "/etc/systemd/system/hwtunnel-$n-firewall.service"; fi
    die "tunnel $n is back on port $old here; the other server returns to $old by itself (it saw no session on $p). Check with manage.sh status-both $n in a minute; if the other server stayed on $p, run there: manage.sh tunnel-port $n $old"
  fi
  [ $rc = 0 ] || exit $rc
  [ $one = 1 ] || say "tunnel $n now on port $p on both servers; sessions $(sessions "$n") (the pool fills up in the next seconds): manage.sh status-both $n"; }
# set-remote NAME HOST [--keep]: foreign side; the Iran server of this tunnel has a new IP (or host name).
# --keep: keep the new address even if the tunnel does not connect within 30 s (Iran not ready yet).
cmd_set_remote() { local n=$1 h=${2:-} k=${3:-} cur f
  exists "$n"; [ "$(role "$n")" = client ] || die "set-remote is for the foreign (client) side, where the tunnel points at the Iran server. On Iran a new foreign IP only matters for the tunnel firewall: manage.sh set-allow $n IP"
  validhost "$h" || die "bad address '$h' (an IPv4 address or a host name)"
  [ -z "$k" ] || [ "$k" = --keep ] || die "set-remote NAME IP [--keep]"
  cur=$(get "$n" remote_addr)
  [ "${cur%:*}" = "$h" ] && { say "tunnel $n already points at $h"; return 0; }
  ssh_guard "$n"
  NAME=$n; OP="set-remote:${cur%:*}->$h"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  setkey "$f" remote_addr "\"$h:${cur##*:}\""
  [ "$k" = --keep ] && KEEP=1
  EXPECT=1 apply "$n" "$f" restart "Iran server of tunnel $n: ${cur%:*} -> $h (tunnel port ${cur##*:} unchanged)"; }
# set-allow NAME IP: Iran side; the foreign server has a new IP. Only the tunnel's firewall rule (install.sh
# --allow-from) names it; without one there is nothing to change.
cmd_set_allow() { local n=$1 ip=${2:-} cur fw re
  exists "$n"; [ "$(role "$n")" = server ] || die "set-allow is for the Iran (server) side; on the foreign side a new Iran IP is set with: manage.sh set-remote $n IP"
  validip "$ip" || die "bad IPv4 address '$ip'"
  [ -f "$ETC/$n.nft" ] || { say "tunnel $n has no firewall rule here: any foreign IP may connect; nothing to change"; return 0; }
  cur=$(grep -oE 'ip saddr != [0-9.]+' "$ETC/$n.nft" | head -1 | awk '{print $4}')
  validip "$cur" || die "the firewall rule of $n has an unexpected form ($ETC/$n.nft); nothing changed"
  [ "$cur" = "$ip" ] && { say "the tunnel port of $n already accepts only $ip"; return 0; }
  ssh_guard "$n"
  NAME=$n; OP="set-allow:$cur->$ip"; begin "$n"; cp -p "$ETC/$n.nft" "$BK/$n.$TX.nft"; fw="$ETC/$n.nft.new-$TX"; re=${cur//./\\.}
  sed -E "s/ip saddr != $re /ip saddr != $ip /; s/only from $re\"/only from $ip\"/" "$ETC/$n.nft" > "$fw"
  grep -q "ip saddr != $ip " "$fw" && nft -c -f "$fw" || { rm -f "$fw"; logtx "$n" "$OP" invalid; die "the new firewall rule failed validation; nothing changed"; }
  confirm "the tunnel port $(tport "$n") of $n accepts only $ip from now on, instead of $cur: the $(sessions "$n") sessions that come from $cur are cut, and the tunnel comes back when the foreign server connects from $ip"
  mv "$fw" "$ETC/$n.nft"
  nft -f "$ETC/$n.nft" || { cp -p "$BK/$n.$TX.nft" "$ETC/$n.nft"; nft -f "$ETC/$n.nft" || true; logtx "$n" "$OP" failed; die "nft could not load the new rule; the previous rule is back"; }
  sed -i "s/only from $re\$/only from $ip/" "/etc/systemd/system/hwtunnel-$n-firewall.service"; systemctl daemon-reload
  logtx "$n" "$OP" ok; say "applied (tx $TX): tunnel port $(tport "$n") of $n accepts only $ip; sessions now $(sessions "$n") (they come back once the foreign server connects from $ip). Undo: manage.sh set-allow $n $cur"; }

cmd_version() { exists "$1"; echo "name=$1 id=$(tid "$1") role=$(role "$1") config=$(cfgver "$1") engine=$("$BIN" -v 2>&1 | head -1) binary=$(readlink "$BIN") service=$(systemctl is-active "hwtunnel-$1") sessions=$(sessions "$1")"; }
cmd_peer_setup() { local n=$1 p used self; exists "$n"
  self=$(readlink -f "$0" 2>/dev/null || true)
  if [ -f "$self" ] && [ "$self" != "$ROOT/bin/manage.sh" ]; then install -m 0750 "$self" "$ROOT/bin/manage.sh"; fi
  [ -f "$ROOT/bin/manage.sh" ] || die "run peer-setup from a manage.sh file (it installs itself to $ROOT/bin/manage.sh)"
  local probe; probe=$("$BIN" peer 2>&1 || true)
  [[ "$probe" == *"serve|run|queue"* ]] || die "this engine has no management agent (it needs the HoneyWeb engine with internal/peer)"
  cat > /etc/systemd/system/hwtunnel-peer.service <<EOF
[Unit]
Description=HoneyWeb Tunnel management agent (loopback only; reached through the tunnels)
After=network-online.target

[Service]
ExecStart=$BIN peer serve --listen $AGENT --etc $ETC --manage $ROOT/bin/manage.sh
Restart=on-failure
RestartSec=3

[Install]
WantedBy=multi-user.target
EOF
  if [ "$(role "$n")" = server ] && [ -z "$(peerport "$n")" ]; then
    used=$(cat "$ETC"/*.peer 2>/dev/null | sed -n 's/^port=//p' || true)
    for p in $(seq 59201 59299); do echo "$used" | grep -qx "$p" && continue; ss -Htln "( sport = :$p )" | grep -q . && continue; break; done
    (YES=1; cmd_ports "$n" add "127.0.0.1:$p=127.0.0.1:59111") || die "could not add the management mapping"
    printf 'port=%s\n' "$p" > "$ETC/$n.peer"; chmod 0600 "$ETC/$n.peer"
  fi
  systemctl daemon-reload; systemctl enable hwtunnel-peer >/dev/null 2>&1; systemctl restart hwtunnel-peer
  sleep 1; systemctl is-active --quiet hwtunnel-peer || die "the agent did not start: journalctl -u hwtunnel-peer"
  say "management agent on $AGENT$([ -n "$(peerport "$n")" ] && echo "; tunnel $n reaches the other side's agent through 127.0.0.1:$(peerport "$n")")"; }
cmd_peer() { local n=$1; shift; exists "$n"; [ $# -gt 0 ] || die "peer NAME CMD ARGS..."
  systemctl is-active --quiet hwtunnel-peer || die "no management agent here (manage.sh peer-setup $n)"
  local rc=0
  if [ "$(role "$n")" = server ]; then
    local p; p=$(peerport "$n"); [ -n "$p" ] || die "tunnel $n has no management mapping (manage.sh peer-setup $n)"
    "$BIN" peer run --tunnel "$n" --to "127.0.0.1:$p" --etc "$ETC" "$@" || rc=$?
  else "$BIN" peer queue --tunnel "$n" --etc "$ETC" "$@" || rc=$?; fi
  if [ $rc = 1 ] && [[ " $* " =~ " "(pool|profile|restart|restore|remove|set-remote|set-allow)" " ]]; then
    # a change that restarts this tunnel cuts the channel its own answer travels on
    echo "manage.sh: the answer did not come back. '$1' may have restarted tunnel $n and with it this management channel, so the change may well be applied: check with 'manage.sh status-both $n' in a few seconds" >&2
  fi
  return $rc; }
cmd_status_both() { local n=$1 here there; exists "$n"; here=$(cmd_version "$n")
  echo "this server:  $here"
  if there=$(cmd_peer "$n" version "$n" 2>&1); then
    echo "other server: $there"
    if [ "$(echo "$there" | grep -o 'id=[0-9a-f]*' | head -1)" = "id=$(tid "$n")" ]; then echo "==> same tunnel on both sides (id $(tid "$n"))"
    else echo "!! the other side reports a different tunnel id"; return 1; fi
  else echo "other server: unreachable through the tunnel ($there)"; echo "!! status of the other side unknown"; return 1; fi; }
cmd_remove_both() { local n=$1 conf=${2:-} name=${3:-} out
  exists "$n"; [ "$conf" = --confirm ] && [ "$name" = "$n" ] || die "type the name to confirm: manage.sh remove-both $n --confirm $n"
  ssh_guard "$n"
  NAME=$n; OP=remove-both
  confirm "remove tunnel $n (id $(tid "$n")) from BOTH servers: $(sessions "$n") sessions and $(users "$n") user connections end. The other side is removed first, 8 s after it confirms (that cuts this management channel), then this side"
  out=$(cmd_peer "$n" remove "$n" --confirm "$n" --delay 8 2>&1) || { echo "$out"; die "the other side did not schedule its removal: NOTHING was removed (tunnel $n is untouched on both sides)"; }
  echo "other side: $out"
  echo "$out" | grep -q "scheduled" || die "the other side did not confirm the schedule: NOTHING was removed here; check the other side"
  (YES=1; cmd_remove "$n" --confirm "$n")
  say "remove-both $n: removed here; the other side confirmed its removal 8 s after its answer (it cannot report back through this tunnel any more: verify there with manage.sh list)"; }

# ---- make-before-break migration (docs/manage/two-sided.md §4) -------------------------------------------------
TXD=$ETC/tx
txset() { printf '%s=%s\n' "$2" "$3" >> "$TXD/$1.state"; }
txget() { sed -n "s/^$2=//p" "$TXD/$1.state" 2>/dev/null | tail -1; }
setkey() { if grep -qE "^$2[[:space:]]*=" "$1"; then sed -i -E "s|^$2[[:space:]]*=.*|$2 = $3|" "$1"; else sed -i "/^\[\(server\|client\)\]/a $2 = $3" "$1"; fi; }
delkey() { sed -i -E "/^$2[[:space:]]*=/d" "$1"; }
validtr() { case "$1" in tcpmux|wsmux|wssmux|tcp|ws|wss|stealth|kcp|quic) return 0;; esac; return 1; }
mainpid() { systemctl show -p MainPID --value "hwtunnel-$1"; }
heldby() { ss -Htlnp "( sport = :$1 )" | grep -o 'pid=[0-9]*' | sort -u | tr '\n' ' '; }
usermaps() { plist "$1" | while read -r m; do if ! is_mgmt "$m"; then echo "$m"; fi; done; }
mtarget() { local m=$1; if [[ "$m" == *=* ]]; then echo "${m#*=}"; else lport "$m"; fi; }
freeport() { local p; for p in $(seq "$1" "$2"); do ss -Htuln "( sport = :$p )" | grep -q . || { echo "$p"; return 0; }; done; return 1; }
newunit() { local src=$1 dst=$2 caps=${3:-}
  sed -e "s|$ETC/$src.toml|$ETC/$dst.toml|" -e "s|^Description=.*|Description=HoneyWeb Tunnel $dst (from $src)|" "/etc/systemd/system/hwtunnel-$src.service" > "/etc/systemd/system/hwtunnel-$dst.service"
  if [ -n "$caps" ]; then sed -i -E 's/^CapabilityBoundingSet=.*/CapabilityBoundingSet=CAP_NET_BIND_SERVICE/; s/^AmbientCapabilities=.*/AmbientCapabilities=CAP_NET_BIND_SERVICE/' "/etc/systemd/system/hwtunnel-$dst.service"; fi; }
dropinst() { local n=$1 d; systemctl disable --now "hwtunnel-$n" "hwtunnel-$n-firewall" >/dev/null 2>&1 || true
  d="$ETC/removed/$n.$(date -u +%Y%m%dT%H%M%SZ)-$$"; install -d -m 0700 "$d"
  for f in "$ETC/$n".*; do [ -e "$f" ] && mv "$f" "$d/"; done
  mv "/etc/systemd/system/hwtunnel-$n.service" "/etc/systemd/system/hwtunnel-$n-firewall.service" "$d/" 2>/dev/null || true
  systemctl daemon-reload; }
retarget_cfg() { local f=$1 tr=$2; setkey "$f" transport "\"$tr\""
  case "$tr" in wsmux|wssmux) setkey "$f" mux_version 2;; tcpmux) delkey "$f" mux_version;; esac; }

# clone-server SRC DST TRANSPORT TUNNEL_PORT PROBE_PORT: a second server tunnel next to SRC with its token, a new
# transport/port, and only a loopback probe mapping (no user port yet). SRC is not touched.
cmd_clone_server() { local src=$1 dst=$2 tr=$3 tp=$4 probe=$5 f t caps=""
  exists "$src"; [ "$(role "$src")" = server ] || die "clone-server: $src is not a server tunnel"
  [[ "$dst" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ ! -e "$(cfg "$dst")" ] && [ ! -e "/etc/systemd/system/hwtunnel-$dst.service" ] || die "clone-server: '$dst' exists here or is not a valid name"
  validtr "$tr" || die "unknown transport $tr"; [[ "$tp" =~ ^[0-9]+$ && "$probe" =~ ^[0-9]+$ ]] || die "bad port"
  ss -Htuln "( sport = :$tp )" | grep -q . && die "tunnel port $tp is in use here"
  t=$(mtarget "$(usermaps "$src" | head -1)"); [ -n "$t" ] || die "$src has no user mapping to probe"
  f=$(cfg "$dst"); cp -p "$(cfg "$src")" "$f"
  retarget_cfg "$f" "$tr"; setkey "$f" bind_addr "\"0.0.0.0:$tp\""; setkey "$f" user_port_reuse true
  sed -i -E "s|^ports[[:space:]]*=.*|ports = [\"127.0.0.1:$probe=$t\"]|" "$f"
  delkey "$f" tls_cert; delkey "$f" tls_key
  case "$tr" in wss|wssmux)
    openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 -subj "/CN=honeyweb-tunnel" \
      -keyout "$ETC/$dst.key" -out "$ETC/$dst.crt" 2>/dev/null || { rm -f "$f"; die "could not make a TLS certificate"; }
    chown root:hwtunnel "$ETC/$dst.key" "$ETC/$dst.crt"; chmod 0640 "$ETC/$dst.key" "$ETC/$dst.crt"
    setkey "$f" tls_cert "\"$ETC/$dst.crt\""; setkey "$f" tls_key "\"$ETC/$dst.key\"";;
  esac
  chown root:hwtunnel "$f"; chmod 0640 "$f"
  "$BIN" check -c "$f" >/dev/null 2>&1 || { "$BIN" check -c "$f" 2>&1 | tail -2; dropinst "$dst"; die "the new config failed hwtunnel check"; }
  [ "$tp" -lt 1024 ] && caps=1; newunit "$src" "$dst" "$caps"
  if [ -f "$ETC/$src.nft" ]; then
    sed -e "s/hwtunnel_$src/hwtunnel_$dst/g" -e "s/dport $(tport "$src")/dport $tp/g" "$ETC/$src.nft" > "$ETC/$dst.nft"
    sed -e "s|$ETC/$src.nft|$ETC/$dst.nft|; s/hwtunnel_$src/hwtunnel_$dst/; s/hwtunnel-$src.service/hwtunnel-$dst.service/; s/tunnel port [0-9]*/tunnel port $tp/" \
      "/etc/systemd/system/hwtunnel-$src-firewall.service" > "/etc/systemd/system/hwtunnel-$dst-firewall.service"
    nft -c -f "$ETC/$dst.nft" || { dropinst "$dst"; die "firewall rule for $tp failed validation"; }
  fi
  systemctl daemon-reload
  [ -f "$ETC/$dst.nft" ] && systemctl enable --now "hwtunnel-$dst-firewall" >/dev/null 2>&1
  systemctl enable --now "hwtunnel-$dst" >/dev/null 2>&1
  local i; for i in $(seq 1 20); do ss -Htlnp "( sport = :$tp )" | grep -q hwtunnel && break; sleep 1; done
  ss -Htlnp "( sport = :$tp )" | grep -q hwtunnel || { journalctl -u "hwtunnel-$dst" -n 5 --no-pager -o cat; dropinst "$dst"; die "$dst does not listen on $tp"; }
  say "clone-server: $dst ($tr) listens on $tp; probe 127.0.0.1:$probe -> $t"; }

# clone-client SRC DST --transport T --remote-port P: a second client next to SRC, same token and pool, to the new
# server port. SRC is not touched.
cmd_clone_client() { local src=$1 dst=$2 tr="" rp="" f host i
  shift 2; while [ $# -gt 0 ]; do case "$1" in --transport) tr=$2; shift 2;; --remote-port) rp=$2; shift 2;; *) die "clone-client: unknown $1";; esac; done
  exists "$src"; [ "$(role "$src")" = client ] || die "clone-client: $src is not a client tunnel"
  [[ "$dst" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] && [ ! -e "$(cfg "$dst")" ] && [ ! -e "/etc/systemd/system/hwtunnel-$dst.service" ] || die "clone-client: '$dst' exists here or is not a valid name"
  validtr "$tr" || die "unknown transport $tr"; [[ "$rp" =~ ^[0-9]+$ ]] || die "bad --remote-port"
  f=$(cfg "$dst"); cp -p "$(cfg "$src")" "$f"; retarget_cfg "$f" "$tr"
  host=$(get "$src" remote_addr | sed 's/:[0-9]*$//'); setkey "$f" remote_addr "\"$host:$rp\""
  "$BIN" check -c "$f" >/dev/null 2>&1 || { dropinst "$dst"; die "the new client config failed hwtunnel check"; }
  newunit "$src" "$dst"; systemctl daemon-reload; systemctl enable --now "hwtunnel-$dst" >/dev/null 2>&1
  for i in $(seq 1 30); do [ "$(sessions "$dst")" -ge 2 ] && break; sleep 1; done
  [ "$(sessions "$dst")" -ge 2 ] || { journalctl -u "hwtunnel-$dst" -n 5 --no-pager -o cat; dropinst "$dst"; die "client $dst did not connect to port $rp"; }
  say "clone-client: $dst ($tr) connected to $host:$rp with $(sessions "$dst") sessions"; }

mig_abort() { local tx=$1 n o step U
  n=$(txget "$tx" new); o=$(txget "$tx" name); step=$(txget "$tx" step)
  echo "== aborting migration $tx at step '$step': $o stays, $n is removed"
  if [ "$step" = handover ] || [ "$step" = mgmt ]; then
    U=$(txget "$tx" usermaps)
    (YES=1; HWT_HANDOVER_PID=$(mainpid "$n"); export HWT_HANDOVER_PID; cmd_ports "$o" set "$U") || echo "!! could not give the user ports back to $o: do it by hand (manage.sh ports $o set $U)"
  fi
  if [ -n "$(txget "$tx" client)" ]; then cmd_peer "$o" remove "$n" --confirm "$n" 2>&1 | tail -1 || echo "!! remove $n on the other server by hand"; fi
  [ -e "$(cfg "$n")" ] && dropinst "$n"
  txset "$tx" step aborted; logtx "$o" "migrate:$tx" aborted; return 1; }

cmd_migrate() { local o=$1 tr="" tp="" n="" drain=600 bg=0 tx="" probe U P2 out pid i c d0
  shift; while [ $# -gt 0 ]; do case "$1" in --transport) tr=$2; shift 2;; --tunnel-port) tp=$2; shift 2;; --new-name) n=$2; shift 2;;
    --drain) drain=$2; shift 2;; --background) bg=1; shift;; --tx) tx=$2; shift 2;; *) die "migrate: unknown $1";; esac; done
  exists "$o"; [ "$(role "$o")" = server ] || die "migrate runs on the Iran (server) side: from abroad use 'manage.sh peer $o migrate ... --background'"
  validtr "$tr" || die "--transport is one of tcpmux wsmux wssmux tcp ws wss stealth kcp quic"; [[ "$tp" =~ ^[0-9]+$ ]] || die "--tunnel-port is required"
  [[ "$drain" =~ ^[0-9]+$ ]] || die "--drain takes seconds"
  [ -n "$(peerport "$o")" ] || die "tunnel $o has no management channel: run manage.sh peer-setup $o on both servers first"
  [ -n "$n" ] || { n=$tr; [ -e "$(cfg "$n")" ] && n="$tr-2"; }
  install -d -m 0700 "$TXD"
  if [ $bg = 1 ]; then
    tx=$(date -u +%Y%m%dT%H%M%SZ)-$$; txset "$tx" name "$o"; txset "$tx" step queued
    systemd-run --quiet --unit="hwt-migrate-$tx" --collect /bin/bash "$ROOT/bin/manage.sh" migrate "$o" --transport "$tr" --tunnel-port "$tp" --new-name "$n" --drain "$drain" --tx "$tx" --yes \
      || die "could not start the migration"
    say "migration $tx started in the background ($o -> $n, $tr on $tp): manage.sh migrate-status $tx"; return 0
  fi
  exec {MLOCK}>/run/hwtunnel-migrate.lock; flock -n "$MLOCK" || die "another migration is running"
  [ -n "$tx" ] || tx=$(date -u +%Y%m%dT%H%M%SZ)-$$
  out=$(cmd_peer "$o" version "$o" 2>&1) || die "the other server is not reachable through $o ($out): nothing changed"
  cmd_peer "$o" version "$n" >/dev/null 2>&1 && die "the other server already has a tunnel named $n: pick --new-name"
  probe=$(freeport 59300 59399) || die "no free probe port"
  U=$(usermaps "$o" | paste -sd,); [ -n "$U" ] || die "$o has no user mappings"
  txset "$tx" name "$o"; txset "$tx" new "$n"; txset "$tx" transport "$tr"; txset "$tx" tport "$tp"; txset "$tx" usermaps "$U"; txset "$tx" step start
  NAME=$o; OP="migrate:$tx"
  confirm "migrate tunnel $o ($(get "$o" transport) on $(tport "$o")) to $n ($tr on $tp), make-before-break: $n is built and checked next to $o; then the user ports ($U) move to it$([ "$(get "$o" user_port_reuse)" = true ] && echo " with no gap" || echo " ($o has no user_port_reuse: new users may see a gap of a few milliseconds)"); connections already open stay on $o until they end (drain up to $drain s); then $o is removed on both servers"
  echo "== [1/7] server $n next to $o"
  (cmd_clone_server "$o" "$n" "$tr" "$tp" "$probe") || { txset "$tx" step failed-server; mig_abort "$tx"; die "migration $tx: the new server did not come up; $o is unchanged"; }
  txset "$tx" step server
  echo "== [2/7] client $n on the other server"
  out=$(cmd_peer "$o" clone-client "$o" "$n" --transport "$tr" --remote-port "$tp" 2>&1); echo "   $out" | tail -2
  echo "$out" | grep -q "clone-client: $n" || { mig_abort "$tx"; die "migration $tx: the new client did not connect; $o is unchanged"; }
  txset "$tx" client yes; txset "$tx" step client
  echo "== [3/7] health of $n: sessions and an end-to-end probe"
  for i in $(seq 1 30); do [ "$(sessions "$n")" -ge $(( $(sessions "$o") * 9 / 10 )) ] && break; sleep 1; done
  # the new tunnel opens its listeners once its first sessions pair, and under load that can take a while: up to
  # 10 tries over ~20 s; a probe passes when the connection through the new tunnel stays open for 2 s
  c=""; for i in $(seq 1 10); do
    c=$(timeout 8 bash -c "exec 3<>/dev/tcp/127.0.0.1/$probe || exit 9; s=\$(date +%s%N); timeout 2 cat <&3 >/dev/null; echo \$(( (\$(date +%s%N)-s)/1000000 ))" 2>/dev/null || true)
    [ "${c:-0}" -ge 1500 ] && break; sleep 2; done
  echo "   sessions $n=$(sessions "$n") $o=$(sessions "$o"); probe held ${c:-?} ms"
  [ "$(sessions "$n")" -ge $(( $(sessions "$o") * 9 / 10 )) ] && [ "${c:-0}" -ge 1500 ] || { mig_abort "$tx"; die "migration $tx: $n is not healthy (sessions or probe); $o is unchanged"; }
  txset "$tx" step verified
  echo "== [4/7] user ports $U: $o -> $n"
  pid=$(mainpid "$o")
  if [ "$(get "$o" user_port_reuse)" = true ]; then
    (YES=1; export HWT_HANDOVER_PID=$pid; cmd_ports "$n" set "127.0.0.1:$probe=$(mtarget "${U%%,*}"),$U") || { mig_abort "$tx"; die "migration $tx: $n could not take the user ports; $o is unchanged"; }
    (YES=1; cmd_ports "$o" set "$(plist "$o" | while read -r m; do if is_mgmt "$m"; then echo "$m"; fi; done | head -1)") || true
  else
    (YES=1; cmd_ports "$o" set "$(plist "$o" | while read -r m; do if is_mgmt "$m"; then echo "$m"; fi; done | head -1)") || { mig_abort "$tx"; die "migration $tx: could not release the ports on $o"; }
    (YES=1; export HWT_HANDOVER_PID=$pid; cmd_ports "$n" set "127.0.0.1:$probe=$(mtarget "${U%%,*}"),$U") || { txset "$tx" step handover; mig_abort "$tx"; die "migration $tx: $n could not take the user ports; they were given back to $o"; }
  fi
  txset "$tx" step handover
  local np; np=$(mainpid "$n")
  for m in ${U//,/ }; do c=$(heldby "$(lport "$m")"); echo "   :$(lport "$m") held by $c(new tunnel pid=$np)"
    [[ " $c" == *" pid=$np "* ]] || { mig_abort "$tx"; die "migration $tx: port $(lport "$m") is not served by $n; the ports were given back to $o"; }; done
  echo "== [5/7] management channel -> $n"
  P2=$(freeport 59201 59299) || { mig_abort "$tx"; die "no free management port"; }
  (YES=1; cmd_ports "$n" set "$U,127.0.0.1:$P2=127.0.0.1:59111") || { mig_abort "$tx"; die "migration $tx: could not move the management channel"; }
  printf 'port=%s\n' "$P2" > "$ETC/$n.peer"; chmod 0600 "$ETC/$n.peer"; systemctl restart hwtunnel-peer; sleep 3
  cmd_peer "$n" version "$n" >/dev/null 2>&1 || { mig_abort "$tx"; die "migration $tx: the management channel through $n does not answer"; }
  txset "$tx" step mgmt
  txset "$tx" drain "$drain"
  mig_finish "$tx"; }

# mig_finish TX: steps 6-7 (drain the old tunnel, remove it on both servers), also for migrate-resume.
mig_finish() { local tx=$1 o n U drain pid c d0 out step
  o=$(txget "$tx" name); n=$(txget "$tx" new); U=$(txget "$tx" usermaps); drain=$(txget "$tx" drain); step=$(txget "$tx" step)
  drain=${drain:-600}
  if [ "$step" != drained ]; then
    echo "== [6/7] drain $o: open connections finish on it (up to $drain s)"
    pid=$(mainpid "$o"); d0=$(date +%s)
    while :; do c=0
      for m in ${U//,/ }; do c=$(( c + $(ss -Htnp state established "( sport = :$(lport "$m") )" | grep -c "pid=$pid," || true) )); done
      [ "$c" = 0 ] && break
      [ $(( $(date +%s) - d0 )) -ge "$drain" ] && { echo "   drain deadline: $c connections still on $o are cut now"; break; }
      sleep 5; done
    echo "   drained after $(( $(date +%s) - d0 )) s"; txset "$tx" step drained
  fi
  echo "== [7/7] remove $o on both servers"
  out=$(cmd_peer "$n" remove "$o" --confirm "$o" 2>&1 || true); echo "   other server: $(echo "$out" | tail -1)"
  if [ -e "$(cfg "$o")" ]; then (YES=1; HWT_SSH_OK=1; cmd_remove "$o" --confirm "$o") | tail -1; fi
  systemctl restart hwtunnel-peer   # stop polling the removed tunnel's mapping
  txset "$tx" step done; logtx "$o" "migrate:$tx->$n" ok
  say "migration $tx done: $n carries the user ports $U; $o is removed on both servers"; }
# migrate-resume TX: after an interruption, finish a migration whose user ports already moved, or undo one that
# had not got that far. A half-done migration is never left as if it had succeeded.
cmd_migrate_resume() { local tx=$1 step; [ -f "$TXD/$tx.state" ] || die "no migration $tx"; step=$(txget "$tx" step)
  exec {MLOCK}>/run/hwtunnel-migrate.lock; flock -n "$MLOCK" || die "another migration is running"
  case "$step" in
    mgmt|drained) echo "== resuming migration $tx after step $step"; mig_finish "$tx";;
    handover) echo "== migration $tx stopped right after the port handover: finishing the management move is not resumable; undoing it"; mig_abort "$tx" || true;;
    done) say "migration $tx is already done";;
    aborted) say "migration $tx was aborted";;
    *) echo "== migration $tx stopped at step '$step', before the user ports moved: undoing it"; mig_abort "$tx" || true;;
  esac; }
cmd_migrate_status() { [ -f "$TXD/$1.state" ] || die "no migration $1"; cat "$TXD/$1.state"; local u; u=$(systemctl is-active "hwt-migrate-$1" 2>/dev/null || true); echo "background unit: ${u:-none}"; }
cmd_migrate_list() { ls -1 "$TXD"/*.state 2>/dev/null | while read -r f; do echo "  $(basename "$f" .state)  $(sed -n 's/^step=//p' "$f" | tail -1)"; done; }

menu() { local ch n a b d v
  while :; do echo; echo "$(c '1;33' 'HoneyWeb Tunnel Manager')"; cmd_list; echo
    echo "  1) Show a tunnel            2) Port mappings (add / remove / change port)"
    echo "  3) Change the tunnel port   4) Server IP changed"
    echo "  5) Remove a tunnel          6) Status of both servers"
    echo "  7) Connection pool          8) Performance profile"
    echo "  9) Restart a tunnel        10) Backups / restore"
    echo " 11) Migrate (new transport or port, no cut; the name changes)   0) Exit"
    read -r -p "Choose: " ch || exit 0; [ "$ch" = 0 ] && exit 0
    read -r -p "Tunnel name: " n || exit 0
    case "$ch" in
      1) cmd_show "$n" || true;;
      2) (cmd_ports "$n" list) || continue
         echo "  add MAP          e.g. add 2083  or  add 8443=443"
         echo "  del PORT         stop listening on PORT"
         echo "  move OLD NEW     users connect to NEW instead of OLD (same target)"
         echo "  set MAP,MAP...   the whole list"
         read -r -p "Command (Enter = back): " a b d || true; [ -n "${a:-}" ] && { (cmd_ports "$n" "$a" "${b:-}" "${d:-}") || true; };;
      3) read -r -p "New tunnel port: " v || true; (cmd_tunnel_port "$n" "${v:-}") || true;;
      4) if (exists "$n") && [ "$(role "$n")" = client ]; then read -r -p "New IP of the Iran server: " v || true; (cmd_set_remote "$n" "${v:-}") || true
         else read -r -p "New IP of the foreign server: " v || true; (cmd_set_allow "$n" "${v:-}") || true; fi;;
      5) read -r -p "Remove from 1) this server only  2) both servers: " d || true
         read -r -p "Type the name again to remove it: " v || true
         case "${d:-}" in 2) (cmd_remove_both "$n" --confirm "${v:-}") || true;; *) (cmd_remove "$n" --confirm "${v:-}") || true;; esac;;
      6) (cmd_status_both "$n") || true;;
      7) read -r -p "New connection_pool: " v || true; (cmd_pool "$n" "${v:-}") || true;;
      8) read -r -p "turbo or default: " v || true; (cmd_profile "$n" "${v:-}") || true;;
      9) (cmd_restart "$n") || true;;
      10) cmd_backups "$n" || true; read -r -p "TXID to restore (Enter = none): " v || true; [ -n "${v:-}" ] && { (cmd_restore "$n" "$v") || true; };;
      11) read -r -p "Transport (tcpmux wsmux wssmux tcp ws wss stealth kcp quic): " a || true; read -r -p "Tunnel port: " v || true
          (cmd_migrate "$n" --transport "${a:-}" --tunnel-port "${v:-}") || true;;
    esac
  done; }

case "${1:-menu}" in
  menu) menu;;
  list) cmd_list;;
  show) cmd_show "${2:?NAME}";;
  ports) cmd_ports "${2:?NAME}" "${3:-list}" "${4:-}" "${5:-}";;
  tunnel-port) shift; cmd_tunnel_port "${1:?NAME}" "${2:-}" "${@:3}";;
  set-remote) cmd_set_remote "${2:?NAME}" "${3:-}" "${4:-}";;
  set-allow) cmd_set_allow "${2:?NAME}" "${3:-}";;
  pool) cmd_pool "${2:?NAME}" "${3:-}" "${4:-}";;
  profile) cmd_profile "${2:?NAME}" "${3:-}";;
  restart) cmd_restart "${2:?NAME}";;
  backups) cmd_backups "${2:?NAME}";;
  restore) cmd_restore "${2:?NAME}" "${3:-}";;
  remove) cmd_remove "${2:?NAME}" "${3:-}" "${4:-}" "${5:-}" "${6:-}";;
  version) cmd_version "${2:?NAME}";;
  peer-setup) cmd_peer_setup "${2:?NAME}";;
  peer) n=${2:?NAME}; shift 2; cmd_peer "$n" "$@";;
  status-both) cmd_status_both "${2:?NAME}";;
  remove-both) cmd_remove_both "${2:?NAME}" "${3:-}" "${4:-}";;
  clone-client) shift; cmd_clone_client "$@";;
  migrate) shift; cmd_migrate "$@";;
  migrate-status) cmd_migrate_status "${2:?TXID}";;
  migrate-abort) mig_abort "${2:?TXID}" || true;;
  migrate-resume) cmd_migrate_resume "${2:?TXID}";;
  migrate-list) cmd_migrate_list;;
  -h|--help|help) awk 'NR > 1 && /^#/ { print; next } NR > 1 { exit }' "$0";;
  *) die "unknown command '$1' (manage.sh help)";;
esac
