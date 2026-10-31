#!/usr/bin/env bash
# HoneyWeb Tunnel installer (run as root on each server).
#
#   Iran / entry server:
#     bash install.sh server --transport wssmux --tunnel-port 9090 --port 540
#   Foreign / exit client (token printed by the server install):
#     bash install.sh client --transport wssmux --server 203.0.113.10:9090 --token <TOKEN>
#   Other commands:
#     bash install.sh upgrade [--version TAG | --binary FILE]   # binary only, configs are never rewritten
#     bash install.sh rollback                                  # back to the previous binary
#     bash install.sh status
#     bash install.sh uninstall --name NAME
#   --transport: wssmux, tcpmux (Recommended, proven in production), wsmux, tcp, ws, wss, stealth, kcp, quic (UDP).
#   --token-file FILE reads the token from FILE (then deletes it) and never prints it (used by remote installs).
#   iran.sh and kharej.sh next to this file are interactive wizards around it.
#
# Layout: /opt/hwtunnel/bin/hwtunnel-<version> (+ symlink hwtunnel), /opt/hwtunnel/etc/<name>.toml,
# unit hwtunnel-<name>.service running as the unprivileged user hwtunnel, hardened, LimitNOFILE=1048576.
# The configs use the "HoneyWeb Recommended" profile (honeyweb/RECOMMENDED.md): the tuning proven in
# production plus an explicit, generous connection_pool. skip_optz = true always: the engine never writes sysctl.
#
# Safety: nothing that already exists is changed. A port in use, an existing unit or config with the same
# name, or a missing dependency stops the install before anything is written. Only files under
# /opt/hwtunnel, the hwtunnel-<name> unit(s) and (with --allow-from) one nftables table of its own are created.
set -euo pipefail
umask 022   # a strict caller umask (077) would make /opt/hwtunnel unreadable for the service user

VERSION_DEFAULT="hw-v1.1.0"
REPO_DEFAULT="mahansh1999/HoneyWeb-Tunnel"
ROOT=/opt/hwtunnel
BIN_DIR=$ROOT/bin
ETC=$ROOT/etc
USER_NAME=hwtunnel

# HoneyWeb Recommended: performance profile (same on both ends) and capacity policy.
PERF_COMMON='nodelay = true
mux_streambuffer = 2097152
mux_recievebuffer = 16777216'
MUX_CON=8              # streams per session on the server (engine default, written explicitly)
# Default capacity per transport, from HoneyWeb production peaks (2026-10-31: WSSMUX 5312 and TCPMUX 2464 concurrent
# streams at the evening peak): wssmux 896 sessions = 7168 streams, tcpmux/wsmux 512 = 4096. tcp/udp families keep
# 64 connections ready (engine default 8). --pool overrides.
pool_default() { case "$1" in wssmux) echo 896;; tcpmux|wsmux) echo 512;; *) echo 64;; esac; }

# Transport families. mux: many user connections share one session (the Recommended profile, proven in
# production). tcp: one tunnel connection per user connection. udp: KCP or QUIC over UDP, with the engine's own
# tuning (nodelay and the smux windows are TCP/mux settings and are not written for them).
TRANSPORTS="wssmux tcpmux wsmux tcp ws wss stealth kcp quic"
family() { case "$1" in tcpmux|wsmux|wssmux) echo mux;; tcp|ws|wss|stealth) echo tcp;; kcp|quic) echo udp;; *) echo none;; esac; }

die() { echo "install.sh: $*" >&2; exit 1; }
say() { echo "==> $*" >&2; }

usage() { sed -n '2,13p' "$0"; exit 2; }

[ "$(id -u)" = 0 ] || die "run as root"
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT   # downloads and checks happen here; removed on any exit
cmd=${1:-}; [ -n "$cmd" ] || usage; shift

transport=""; tunnel_port=""; ports=(); name=""; token=""; server=""; pool=""
version=$VERSION_DEFAULT; repo=$REPO_DEFAULT; binary=""; allow_from=""; yes=0; token_quiet=0
while [ $# -gt 0 ]; do
  case "$1" in
    --transport) transport=$2; shift 2;;
    --tunnel-port) tunnel_port=$2; shift 2;;
    --port) IFS=, read -ra add <<<"$2"; ports+=("${add[@]}"); shift 2;;
    --name) name=$2; shift 2;;
    --token) token=$2; shift 2;;
    --token-file) token=$(tr -d ' 
' < "$2"); rm -f "$2"; token_quiet=1; shift 2;;
    --server) server=$2; shift 2;;
    --pool) pool=$2; shift 2;;
    --version) version=$2; shift 2;;
    --repo) repo=$2; shift 2;;
    --binary) binary=$2; shift 2;;
    --allow-from) allow_from=$2; shift 2;;
    --yes) yes=1; shift;;
    -h|--help) usage;;
    *) die "unknown option $1";;
  esac
done

arch() {
  case "$(uname -m)" in
    x86_64|amd64) echo amd64;;
    aarch64|arm64) echo arm64;;
    *) die "unsupported architecture $(uname -m)";;
  esac
}

need() { for c in "$@"; do command -v "$c" >/dev/null 2>&1 || die "missing dependency: $c"; done; }

port_in_use() { ss -Htln "( sport = :$1 )" 2>/dev/null | grep -q .; }
udp_in_use() { ss -Huln "( sport = :$1 )" 2>/dev/null | grep -q .; }

# Download (or take) the binary for this architecture and verify it against SHA256SUMS of the release.
fetch_binary() {
  local a out sums
  a=$(arch); out=$WORK
  if [ -n "$binary" ]; then
    cp "$binary" "$out/hwtunnel-linux-$a"
    if [ -f "$(dirname "$binary")/SHA256SUMS" ]; then cp "$(dirname "$binary")/SHA256SUMS" "$out/"; fi
  else
    need curl
    local base="https://github.com/$repo/releases/download/$version" auth=()
    [ -n "${GITHUB_TOKEN:-}" ] && auth=(-H "Authorization: Bearer $GITHUB_TOKEN")
    if [ ${#auth[@]} -gt 0 ]; then
      # private repository: resolve the asset ids through the API
      local api="https://api.github.com/repos/$repo/releases/tags/$version" rel id f
      rel=$(curl -fsSL "${auth[@]}" "$api") || die "cannot read release $version of $repo"
      for f in "hwtunnel-linux-$a" SHA256SUMS; do
        id=$(printf '%s' "$rel" | tr -d '\n' | grep -o "\"url\": *\"[^\"]*/assets/[0-9]*\"[^}]*\"name\": *\"$f\"" | grep -o 'assets/[0-9]*' | head -1 | cut -d/ -f2)
        [ -n "$id" ] || die "release $version has no asset $f"
        curl -fsSL "${auth[@]}" -H "Accept: application/octet-stream" -o "$out/$f" "https://api.github.com/repos/$repo/releases/assets/$id"
      done
    else
      curl -fsSL -o "$out/hwtunnel-linux-$a" "$base/hwtunnel-linux-$a" || die "download failed: $base/hwtunnel-linux-$a"
      curl -fsSL -o "$out/SHA256SUMS" "$base/SHA256SUMS" || die "download failed: $base/SHA256SUMS"
    fi
  fi
  if [ -f "$out/SHA256SUMS" ]; then
    (cd "$out" && grep -E " [*]?hwtunnel-linux-$a$" SHA256SUMS | sha256sum -c --quiet -) || die "checksum mismatch for hwtunnel-linux-$a"
    say "binary verified: $(sha256sum "$out/hwtunnel-linux-$a" | cut -c1-16)…"
  else
    [ $yes = 1 ] || die "no SHA256SUMS next to $binary; pass --yes to install an unverified binary"
  fi
  chmod 0755 "$out/hwtunnel-linux-$a"
  echo "$out/hwtunnel-linux-$a"
}

install_binary() {
  local src=$1 tag=$2
  # A new tunnel next to existing ones must not switch their binary: reuse the same build or stop.
  if [ "$cmd" != upgrade ] && [ -L "$BIN_DIR/hwtunnel" ]; then
    local cur; cur=$(readlink "$BIN_DIR/hwtunnel")
    if cmp -s "$src" "$BIN_DIR/$cur"; then   # same build, whatever release tag it came with
      say "binary: $BIN_DIR/hwtunnel -> $cur already installed (same build)"; return
    fi
    die "another HoneyWeb Tunnel binary is active ($cur) and other tunnels use it; nothing changed (run 'install.sh upgrade' first)"
  fi
  install -d -m 0755 "$ROOT" "$BIN_DIR"
  install -m 0755 "$src" "$BIN_DIR/hwtunnel-$tag.new"
  "$BIN_DIR/hwtunnel-$tag.new" -v >/dev/null || die "the downloaded binary does not run on this host"
  mv "$BIN_DIR/hwtunnel-$tag.new" "$BIN_DIR/hwtunnel-$tag"
  if [ -L "$BIN_DIR/hwtunnel" ] && [ "$(readlink "$BIN_DIR/hwtunnel")" != "hwtunnel-$tag" ]; then
    readlink "$BIN_DIR/hwtunnel" > "$BIN_DIR/.previous"
  fi
  ln -sfn "hwtunnel-$tag" "$BIN_DIR/hwtunnel"
  say "binary: $BIN_DIR/hwtunnel -> hwtunnel-$tag ($("$BIN_DIR/hwtunnel" -v | head -1))"
}

ensure_user() {
  id "$USER_NAME" >/dev/null 2>&1 || useradd --system --no-create-home --home-dir "$ROOT" --shell /usr/sbin/nologin "$USER_NAME"
  install -d -m 0750 -o root -g "$USER_NAME" "$ETC"
}

listen_port() { local m=$1; m=${m%%=*}; echo "${m##*:}"; }

write_unit() {
  local n=$1 caps=$2 role=$3
  cat > "/etc/systemd/system/hwtunnel-$n.service" <<EOF
[Unit]
Description=HoneyWeb Tunnel $n ($role)
After=network-online.target
Wants=network-online.target

[Service]
User=$USER_NAME
Group=$USER_NAME
ExecStart=$BIN_DIR/hwtunnel -c $ETC/$n.toml
Restart=on-failure
RestartSec=5
RuntimeDirectory=backpack
RuntimeDirectoryPreserve=yes
NoNewPrivileges=yes
ProtectSystem=strict
ProtectHome=yes
PrivateTmp=yes
LimitNOFILE=1048576
CapabilityBoundingSet=$caps
AmbientCapabilities=$caps

[Install]
WantedBy=multi-user.target
EOF
}

write_config() { # name content
  local f=$ETC/$1.toml
  (umask 077; printf '%s\n' "$2" > "$f.new")
  chown root:"$USER_NAME" "$f.new"; chmod 0640 "$f.new"
  "$BIN_DIR/hwtunnel" check -c "$f.new" >/dev/null || { rm -f "$f.new"; die "generated config failed hwtunnel check"; }
  mv "$f.new" "$f"
}

firewall() { # name port source proto
  need nft
  local n=$1 p=$2 src=$3 proto=${4:-tcp} file=$ETC/$1.nft
  cat > "$file" <<EOF
table inet hwtunnel_$n
delete table inet hwtunnel_$n
table inet hwtunnel_$n {
  chain input {
    type filter hook input priority filter; policy accept;
    $proto dport $p ip saddr != $src counter drop comment "hwtunnel $n: tunnel port only from $src"
    meta nfproto ipv6 $proto dport $p counter drop comment "hwtunnel $n: no IPv6 to the tunnel port"
  }
}
EOF
  nft -c -f "$file" || die "nftables rule failed validation; nothing applied"
  cat > "/etc/systemd/system/hwtunnel-$n-firewall.service" <<EOF
[Unit]
Description=HoneyWeb Tunnel $n: tunnel port $p only from $src
Before=hwtunnel-$n.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/usr/sbin/nft -f $file
ExecStop=/usr/sbin/nft delete table inet hwtunnel_$n

[Install]
WantedBy=multi-user.target
EOF
}

health() { # name role port family
  local n=$1 role=$2 p=$3 fam=$4 i since
  since=$(systemctl show -p ActiveEnterTimestamp --value "hwtunnel-$n")
  up() { journalctl -u "hwtunnel-$n" --since "$since" --no-pager -o cat 2>/dev/null | grep -q "control channel established"; }
  for i in $(seq 1 25); do
    sleep 1
    systemctl is-active --quiet "hwtunnel-$n" || continue
    if [ "$role" = server ]; then
      if [ "$fam" = udp ]; then udp_in_use "$p" && break; else port_in_use "$p" && break; fi
    else up && break; fi
  done
  # A new tunnel that is not healthy is stopped and disabled (no restart loop); its files stay for diagnosis.
  local stop="systemctl disable --now hwtunnel-$n >/dev/null 2>&1; journalctl -u hwtunnel-$n -n 20 --no-pager"
  local rm="(stopped; remove with: install.sh uninstall --name $n)"
  systemctl is-active --quiet "hwtunnel-$n" || { eval "$stop"; die "hwtunnel-$n is not running $rm"; }
  if [ "$role" = server ]; then
    if [ "$fam" = udp ]; then udp_in_use "$p"; else port_in_use "$p"; fi || { eval "$stop"; die "hwtunnel-$n runs but does not listen on $p $rm"; }
    say "server up: listening on $p/$([ "$fam" = udp ] && echo udp || echo tcp); waiting for the client to connect"
  else
    up || { eval "$stop"; die "client could not reach the server on port $p (no control channel within 25 s) $rm"; }
    local s=""; [ "$fam" = udp ] || s=" ($(ss -Htn state established "( dport = :$p )" | wc -l) tunnel connections)"
    say "client up: control channel established$s"
  fi
}

case "$cmd" in
  server|client)
    need systemctl ss sha256sum install journalctl
    fam=$(family "$transport")
    [ "$fam" != none ] || die "--transport must be one of: $TRANSPORTS"
    name=${name:-$transport}
    [[ "$name" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "bad --name"
    [ -n "$pool" ] || pool=$(pool_default "$transport")
    [[ "$pool" =~ ^[0-9]+$ ]] && [ "$pool" -ge 8 ] && [ "$pool" -le 8192 ] || die "--pool must be 8..8192"
    [ ! -e "$ETC/$name.toml" ] || die "$ETC/$name.toml already exists; nothing changed (uninstall or pick --name)"
    [ ! -e "/etc/systemd/system/hwtunnel-$name.service" ] || die "unit hwtunnel-$name already exists; nothing changed"
    case "$fam" in
      mux) perf="$PERF_COMMON"; case "$transport" in wsmux|wssmux) perf="$perf
mux_version = 2";; esac;;
      tcp) perf="nodelay = true";;
      udp) perf="";;
    esac
    if [ "$cmd" = server ]; then
      [[ "$tunnel_port" =~ ^[0-9]+$ ]] && [ "$tunnel_port" -ge 1 ] && [ "$tunnel_port" -le 65535 ] || die "--tunnel-port is required (1-65535)"
      [ ${#ports[@]} -gt 0 ] || die "at least one --port is required"
      if [ "$fam" = udp ]; then udp_in_use "$tunnel_port" && die "UDP port $tunnel_port is already in use; nothing changed"
      else port_in_use "$tunnel_port" && die "port $tunnel_port is already in use; nothing changed"; fi
      caps=""
      for m in "${ports[@]}"; do
        lp=$(listen_port "$m"); [[ "$lp" =~ ^[0-9]+$ ]] || die "bad --port $m"
        [ "$fam" != udp ] && [ "$lp" = "$tunnel_port" ] && die "user port $lp is the tunnel port"
        port_in_use "$lp" && die "port $lp is already in use; nothing changed"
        [ "$lp" -lt 1024 ] && caps=CAP_NET_BIND_SERVICE
      done
      [ "$tunnel_port" -lt 1024 ] && caps=CAP_NET_BIND_SERVICE
      [ -n "$token" ] || token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
      ensure_user; install_binary "$(fetch_binary)" "$version"
      tls=""
      case "$transport" in wss|wssmux)
        need openssl
        openssl req -x509 -newkey ec -pkeyopt ec_paramgen_curve:prime256v1 -nodes -days 3650 \
          -subj "/CN=honeyweb-tunnel" -keyout "$ETC/$name.key" -out "$ETC/$name.crt" 2>/dev/null
        chown root:"$USER_NAME" "$ETC/$name.key" "$ETC/$name.crt"; chmod 0640 "$ETC/$name.key" "$ETC/$name.crt"
        tls="tls_cert = \"$ETC/$name.crt\"
tls_key = \"$ETC/$name.key\"";;
      esac
      muxcon=""; [ "$fam" = mux ] && muxcon="mux_con = $MUX_CON"
      plist=$(printf '"%s", ' "${ports[@]}"); plist="[${plist%, }]"
      write_config "$name" "[server]
bind_addr = \"0.0.0.0:$tunnel_port\"
transport = \"$transport\"
token = \"$token\"
skip_optz = true
log_level = \"info\"
$tls
$perf
$muxcon
ports = $plist"
      write_unit "$name" "$caps" "server"
      proto=tcp; [ "$fam" = udp ] && proto=udp
      if [ -n "$allow_from" ]; then firewall "$name" "$tunnel_port" "$allow_from" "$proto"; fi
      systemctl daemon-reload
      [ -n "$allow_from" ] && systemctl enable --now "hwtunnel-$name-firewall" >/dev/null
      systemctl enable --now "hwtunnel-$name" >/dev/null
      health "$name" server "$tunnel_port" "$fam"
      echo "HWT_RESULT ok role=server name=$name transport=$transport tunnel_port=$tunnel_port ports=${ports[*]}${muxcon:+ mux_con=$MUX_CON}"
      if [ "$token_quiet" = 0 ]; then
        echo
        echo "Install the client on the foreign server with:"
        echo "  bash install.sh client --transport $transport --server <THIS_SERVER_IP>:$tunnel_port --token $token --name $name"
        echo "(the token is shown only now; it is stored in $ETC/$name.toml, readable by root and hwtunnel only)"
      fi
    else
      [[ "$server" =~ ^[^:]+:[0-9]+$ ]] || die "--server HOST:PORT is required"
      [ -n "$token" ] || die "--token is required (printed by the server install)"
      ensure_user; install_binary "$(fetch_binary)" "$version"
      write_config "$name" "[client]
remote_addr = \"$server\"
transport = \"$transport\"
token = \"$token\"
connection_pool = $pool
skip_optz = true
log_level = \"info\"
$perf"
      write_unit "$name" "" "client"
      systemctl daemon-reload; systemctl enable --now "hwtunnel-$name" >/dev/null
      health "$name" client "${server##*:}" "$fam"
      cap="pool=$pool"
      if [ "$fam" = mux ]; then
        say "capacity: connection_pool $pool x mux_con $MUX_CON = $((pool * MUX_CON)) concurrent streams"
        cap="$cap streams=$((pool * MUX_CON))"
      fi
      echo "HWT_RESULT ok role=client name=$name transport=$transport server=$server $cap"
    fi
    ;;
  upgrade)
    [ -L "$BIN_DIR/hwtunnel" ] || die "no HoneyWeb Tunnel installation found"
    install_binary "$(fetch_binary)" "$version"
    for u in $(systemctl list-units 'hwtunnel-*.service' --no-legend --plain | awk '{print $1}' | grep -v firewall); do
      systemctl restart "$u"; sleep 2; systemctl is-active --quiet "$u" && say "$u restarted" || echo "WARNING: $u failed; run: bash install.sh rollback"
    done
    say "configs in $ETC were not touched"
    ;;
  rollback)
    [ -s "$BIN_DIR/.previous" ] || die "no previous binary recorded"
    prev=$(cat "$BIN_DIR/.previous"); [ -x "$BIN_DIR/$prev" ] || die "previous binary $prev is missing"
    ln -sfn "$prev" "$BIN_DIR/hwtunnel"
    for u in $(systemctl list-units 'hwtunnel-*.service' --no-legend --plain | awk '{print $1}' | grep -v firewall); do systemctl restart "$u"; done
    say "rolled back to $prev"
    ;;
  status)
    [ -L "$BIN_DIR/hwtunnel" ] && say "binary: $(readlink "$BIN_DIR/hwtunnel") ($("$BIN_DIR/hwtunnel" -v | head -1))"
    systemctl list-units 'hwtunnel-*' --no-legend --no-pager --all || true
    for f in "$ETC"/*.toml; do [ -f "$f" ] && echo "-- $f" && grep -E '^(\[|bind_addr|remote_addr|transport|connection_pool|mux_con|ports)' "$f"; done
    ;;
  uninstall)
    [ -n "$name" ] || die "--name is required"
    systemctl disable --now "hwtunnel-$name" 2>/dev/null || true
    systemctl disable --now "hwtunnel-$name-firewall" 2>/dev/null || true
    rm -f "/etc/systemd/system/hwtunnel-$name.service" "/etc/systemd/system/hwtunnel-$name-firewall.service"
    mkdir -p "$ETC/removed"; for f in "$ETC/$name".*; do [ -e "$f" ] && mv "$f" "$ETC/removed/"; done
    systemctl daemon-reload
    say "hwtunnel-$name removed (its files were moved to $ETC/removed/)"
    ;;
  *) usage;;
esac
