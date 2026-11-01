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
#   manage.sh pool NAME N [--allow-decrease]    connection_pool (foreign/client side)
#   manage.sh profile NAME turbo|default        performance keys only; capacity is never touched
#   manage.sh restart NAME                      restart only this tunnel's service
#   manage.sh backups NAME | restore NAME TXID  configs saved before every change
#   manage.sh remove NAME --confirm NAME        this server's side only; the other side is reported, not touched
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
in_use_by_other() { local p=$1 n=$2 own; own=$(plist "$n" | while read -r m; do lport "$m"; done | grep -qx "$p" && echo y || echo n)
  [ "$own" = y ] && return 1; ss -Htln "( sport = :$p )" | grep -q .; }

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
  [ -n "${EXPECT:-}" ] && before=$EXPECT
  need=$(( before * 9 / 10 )); [ "$need" -lt 1 ] && need=1
  for i in $(seq 1 30); do sleep 1
    systemctl is-active --quiet "hwtunnel-$n" || continue
    ok=1
    if [ "$(role "$n")" = server ]; then
      for m in $(plist "$n"); do p=$(lport "$m"); ss -Htlnp "( sport = :$p )" | grep -q hwtunnel || ok=0; done
      [ "$before" -gt 0 ] && [ "$(sessions "$n")" -lt "$need" ] && ok=0
    else [ "$(sessions "$n")" -lt "$need" ] && ok=0; fi
    [ "${HWT_MANAGE_FAIL_HEALTH:-0}" = 1 ] && ok=0   # tests only: force the rollback path
    [ $ok = 1 ] && return 0
  done; return 1; }
# apply NAME NEWFILE MODE(reload|restart) DESCRIPTION
apply() { local n=$1 new=$2 mode=$3 what=$4 before u
  chown root:hwtunnel "$new"; chmod 0640 "$new"
  "$BIN" check -c "$new" >/dev/null 2>&1 || { "$BIN" check -c "$new" 2>&1 | tail -3; rm -f "$new"; logtx "$n" "$OP" invalid; die "the new config failed hwtunnel check; nothing changed"; }
  before=$(sessions "$n"); u=$(users "$n")
  confirm "$what. Tunnel $n has $before tunnel sessions and $u active user connections; they are cut for about 2-5 s while it $([ "$mode" = restart ] && echo restarts || echo reloads). Other tunnels are not affected."
  mv "$new" "$(cfg "$n")"
  [ "$mode" = restart ] && { systemctl daemon-reload; systemctl restart "hwtunnel-$n"; }
  if healthy "$n" "$before"; then say "applied (tx $TX): sessions $(sessions "$n"), service $(systemctl is-active "hwtunnel-$n")"; logtx "$n" "$OP" ok; return 0; fi
  echo "$(c 31 '!!') unhealthy after the change; rolling back to tx $TX"
  cp -p "$BK/$n.$TX.toml" "$(cfg "$n")"; cp -p "$BK/$n.$TX.service" "/etc/systemd/system/hwtunnel-$n.service"
  systemctl daemon-reload; systemctl restart "hwtunnel-$n"
  if HWT_MANAGE_FAIL_HEALTH=0 healthy "$n" "$before"; then logtx "$n" "$OP" rolled-back; die "change rolled back; the tunnel runs the previous config again"
  else logtx "$n" "$OP" rollback-unhealthy; die "rolled back, but the tunnel is still unhealthy: journalctl -u hwtunnel-$n"; fi; }

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
cmd_ports() { local n=$1 sub=${2:-list} arg=${3:-} cur new m p seen="" caps=0 lost=""
  exists "$n"; [ "$(role "$n")" = server ] || die "port mappings live on the Iran (server) side only; run this there"
  [ "$sub" = list ] && { for m in $(plist "$n"); do p=$(lport "$m"); echo "  $m   listening=$(ss -Htlnp "( sport = :$p )" | grep -q hwtunnel && echo yes || echo NO) users=$(ss -Htn state established "( sport = :$p )" | wc -l)"; done; return; }
  cur=$(plist "$n" | paste -sd,)
  case "$sub" in
    add) validmap "$arg" || die "bad mapping '$arg'"; new="$cur,$arg";;
    del) [[ "$arg" =~ ^[0-9]+$ ]] || die "del takes the listening port"; new=$(plist "$n" | while read -r m; do [ "$(lport "$m")" = "$arg" ] || echo "$m"; done | paste -sd,)
         [ "$new" != "$cur" ] || die "no mapping listens on $arg";;
    set) new=$arg;;
    *) die "ports NAME list|add MAP|del PORT|set MAP[,MAP...]";;
  esac
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
  [ -n "$lost" ] && echo "$(c 33 warning:) port(s)$lost will stop listening: clients configured for them will no longer connect"
  apply "$n" "$f" "$mode" "ports $(echo "$cur" | tr , ' ') -> $(echo "$new" | tr , ' ')"; }
cmd_pool() { local n=$1 v=${2:-} dec=${3:-} cur f
  exists "$n"; [ "$(role "$n")" = client ] || die "connection_pool is set on the foreign (client) side; run this there"
  [[ "$v" =~ ^[0-9]+$ ]] && [ "$v" -ge 8 ] && [ "$v" -le 8192 ] || die "pool must be 8..8192"
  cur=$(get "$n" connection_pool); cur=${cur:-8}
  [ "$v" = "$cur" ] && { say "connection_pool is already $v"; return; }
  [ "$v" -lt "$cur" ] && [ "$dec" != --allow-decrease ] && die "lowering the pool $cur -> $v lowers capacity (the 2026-10-31 saturation came from too small a pool); add --allow-decrease if you mean it"
  NAME=$n; OP="pool:$cur->$v"; begin "$n"; f="$(cfg "$n").new-$TX"; cp -p "$(cfg "$n")" "$f"
  if grep -q '^connection_pool' "$f"; then sed -i -E "s/^connection_pool[[:space:]]*=.*/connection_pool = $v/" "$f"; else sed -i "/^\[client\]/a connection_pool = $v" "$f"; fi
  EXPECT=$(( v + 1 ))   # pool sessions + the control channel
  apply "$n" "$f" reload "connection_pool $cur -> $v ($((v * 8)) streams at mux_con 8)"; }
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
cmd_remove() { local n=$1 conf=${2:-} name=${3:-} d
  exists "$n"; [ "$conf" = --confirm ] && [ "$name" = "$n" ] || die "type the name to confirm: manage.sh remove $n --confirm $n"
  NAME=$n; OP=remove; begin "$n"
  confirm "remove tunnel $n (id $(tid "$n")) from THIS server: $(sessions "$n") sessions and $(users "$n") user connections end now. Its other side keeps running until removed there (manage.sh remove $n there). Binary, other tunnels and other services stay"
  systemctl disable --now "hwtunnel-$n" >/dev/null 2>&1 || true
  systemctl disable --now "hwtunnel-$n-firewall" >/dev/null 2>&1 || true
  d="$ETC/removed/$n.$TX"; install -d -m 0700 "$d"
  for f in "$ETC/$n".*; do [ -e "$f" ] && mv "$f" "$d/"; done
  mv "/etc/systemd/system/hwtunnel-$n.service" "$d/" 2>/dev/null || true; mv "/etc/systemd/system/hwtunnel-$n-firewall.service" "$d/" 2>/dev/null || true
  systemctl daemon-reload; logtx "$n" remove ok
  say "removed from this server; files kept in $d. Other side: still installed (remove it there; it reconnects in vain until then)"; }

menu() { local ch n
  while :; do echo; echo "$(c '1;33' 'HoneyWeb Tunnel Manager')"; cmd_list; echo
    echo " 1) Show a tunnel   2) Port mappings   3) Connection pool   4) Performance profile"
    echo " 5) Restart a tunnel   6) Backups / restore   7) Remove a tunnel   0) Exit"
    read -r -p "Choose: " ch || exit 0; [ "$ch" = 0 ] && exit 0
    read -r -p "Tunnel name: " n || exit 0
    case "$ch" in
      1) cmd_show "$n" || true;;
      2) cmd_ports "$n" list || true; read -r -p "add MAP | del PORT | set MAPS | Enter: " a b || true; [ -n "${a:-}" ] && (cmd_ports "$n" "$a" "${b:-}") || true;;
      3) read -r -p "New connection_pool: " v || true; (cmd_pool "$n" "${v:-}") || true;;
      4) read -r -p "turbo or default: " v || true; (cmd_profile "$n" "${v:-}") || true;;
      5) (cmd_restart "$n") || true;;
      6) cmd_backups "$n" || true; read -r -p "TXID to restore (Enter = none): " v || true; [ -n "${v:-}" ] && (cmd_restore "$n" "$v") || true;;
      7) read -r -p "Type the name again to remove it: " v || true; (cmd_remove "$n" --confirm "${v:-}") || true;;
    esac
  done; }

case "${1:-menu}" in
  menu) menu;;
  list) cmd_list;;
  show) cmd_show "${2:?NAME}";;
  ports) cmd_ports "${2:?NAME}" "${3:-list}" "${4:-}";;
  pool) cmd_pool "${2:?NAME}" "${3:-}" "${4:-}";;
  profile) cmd_profile "${2:?NAME}" "${3:-}";;
  restart) cmd_restart "${2:?NAME}";;
  backups) cmd_backups "${2:?NAME}";;
  restore) cmd_restore "${2:?NAME}" "${3:-}";;
  remove) cmd_remove "${2:?NAME}" "${3:-}" "${4:-}";;
  -h|--help|help) sed -n '2,24p' "$0";;
  *) die "unknown command '$1' (manage.sh help)";;
esac
