#!/usr/bin/env bash
# iran.sh: HoneyWeb Tunnel setup for the Iran (entry) server. Run as root:
#
#   bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/iran.sh)
#
# It asks for three things and installs everything else by itself:
#   transport    how the two servers talk (wssmux and tcpmux are the HoneyWeb Recommended ones)
#   tunnel port  the port on this server that the foreign server connects to (the tunnel itself)
#   user ports   the ports users connect to on this server; each one is carried to the same port on the foreign
#                server (443), or to another one (443=8443)
# At the end it prints a setup link (hwt://...) and ONE command for the foreign server. The link holds this
# server's address, the tunnel port, the transport, the user ports, the capacity and the token, with a checksum:
# the foreign server connects here by itself, and a link cut short in a paste is refused.
#
# Without questions:  iran.sh --transport wssmux --tunnel-port 9090 --port 443[,8443] [--allow-from IP]
#                     [--public-ip IP] [--pool N] [--name NAME] [--yes]
# Other commands are passed to install.sh: iran.sh status | uninstall --name N | upgrade | rollback
set -euo pipefail
umask 022
REPO=${HWT_REPO:-mahansh1999/HoneyWeb-Tunnel}
VERSION=${HWT_VERSION:-latest}
die() { echo "iran.sh: $*" >&2; exit 1; }
c() { printf '\033[%sm%s\033[0m' "$1" "$2"; }
tty_ok() { [ -r /dev/tty ] && [ -w /dev/tty ]; }
ask() { local q=$1 def=${2:-} r; tty_ok || { REPLY=$def; return; }
  read -r -p "$(c '1;36' '?') $q${def:+ [$def]}: " r </dev/tty || true; REPLY=${r:-$def}; }

[ "$(id -u)" = 0 ] || die "run as root (sudo -i first)"
for x in curl ss sha256sum systemctl base64; do command -v $x >/dev/null || die "missing command: $x"; done

# --- release files: next to this script, or downloaded from the release and checked against SHA256SUMS ---
WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT
fetch_release() {
  local a; case "$(uname -m)" in x86_64|amd64) a=amd64;; aarch64|arm64) a=arm64;; *) die "unsupported CPU $(uname -m)";; esac
  local here=""; [ -f "$0" ] && here=$(cd "$(dirname "$0")" && pwd)
  local files=(install.sh SHA256SUMS "hwtunnel-linux-$a") f
  if [ -n "$here" ] && [ -f "$here/install.sh" ] && [ -f "$here/hwtunnel-linux-$a" ] && [ -f "$here/SHA256SUMS" ]; then
    for f in "${files[@]}"; do cp "$here/$f" "$WORK/"; done
    TAG=${HWT_VERSION:-}
  else
    local base="https://github.com/$REPO/releases/latest/download"
    [ "$VERSION" = latest ] || base="https://github.com/$REPO/releases/download/$VERSION"
    if curl -fsSL --retry 2 -o "$WORK/SHA256SUMS" "$base/SHA256SUMS" 2>/dev/null; then
      TAG=$VERSION; [ "$VERSION" != latest ] || TAG=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" | sed 's|.*/tag/||')
      for f in install.sh "hwtunnel-linux-$a"; do curl -fsSL --retry 2 -o "$WORK/$f" "$base/$f" || die "download failed: $f"; done
    else
      # private repository: a GitHub token with read access, never shown and never put on a command line
      if [ -z "${GITHUB_TOKEN:-}" ]; then tty_ok || die "the release is private: set GITHUB_TOKEN"
        read -rs -p "$(c '1;36' '?') GitHub token for the private release (hidden): " GITHUB_TOKEN </dev/tty; echo >/dev/tty; fi
      (umask 077; printf 'Authorization: Bearer %s\n' "$GITHUB_TOKEN" > "$WORK/.auth")
      local api="https://api.github.com/repos/$REPO/releases/latest" rel id
      [ "$VERSION" = latest ] || api="https://api.github.com/repos/$REPO/releases/tags/$VERSION"
      rel=$(curl -fsSL -H @"$WORK/.auth" "$api") || { rm -f "$WORK/.auth"; die "cannot read the release (token or network)"; }
      TAG=$(printf '%s' "$rel" | grep -o '"tag_name": *"[^"]*"' | head -1 | cut -d'"' -f4)
      for f in "${files[@]}"; do
        id=$(printf '%s' "$rel" | tr -d '\n' | grep -o "\"url\": *\"[^\"]*/assets/[0-9]*\"[^}]*\"name\": *\"$f\"" | grep -o 'assets/[0-9]*' | head -1 | cut -d/ -f2)
        [ -n "$id" ] || { rm -f "$WORK/.auth"; die "the release has no $f"; }
        curl -fsSL -H @"$WORK/.auth" -H "Accept: application/octet-stream" -o "$WORK/$f" "https://api.github.com/repos/$REPO/releases/assets/$id" \
          || { rm -f "$WORK/.auth"; die "download failed: $f"; }
      done
      rm -f "$WORK/.auth"
    fi
  fi
  (cd "$WORK" && grep -E " [*]?(install\.sh|hwtunnel-linux-$a)\$" SHA256SUMS | sha256sum -c --quiet -) || die "checksum mismatch: refusing to install"
  BINARY="$WORK/hwtunnel-linux-$a"
  [[ "${TAG:-}" =~ ^[A-Za-z0-9._-]+$ ]] || TAG=""   # empty: install.sh names the binary after its own version
  VERARGS=(); [ -z "$TAG" ] || VERARGS=(--version "$TAG")
}

# Other commands go straight to install.sh.
case "${1:-}" in
  status|uninstall|rollback) fetch_release; rc=0; bash "$WORK/install.sh" "$@" || rc=$?; exit $rc;;
  upgrade) shift; fetch_release; rc=0; bash "$WORK/install.sh" upgrade --binary "$BINARY" "${VERARGS[@]}" "$@" || rc=$?; exit $rc;;
esac

transport=""; tport=""; ports=""; allow=""; pubip=""; name=""; pool=""; yes=0
while [ $# -gt 0 ]; do case "$1" in
  --transport) transport=$2; shift 2;; --tunnel-port) tport=$2; shift 2;; --port) ports=$2; shift 2;;
  --allow-from) allow=$2; shift 2;; --public-ip) pubip=$2; shift 2;; --name) name=$2; shift 2;; --pool) pool=$2; shift 2;;
  --yes|-y) yes=1; shift;; -h|--help) sed -n '2,18p' "$0"; exit 0;; *) die "unknown option $1";; esac; done

TRANSPORTS=(wssmux tcpmux wsmux tcp ws wss stealth kcp quic)
DESC=("WebSocket + TLS, multiplexed        [HoneyWeb Recommended]"
      "TCP, multiplexed                    [HoneyWeb Recommended]"
      "WebSocket, multiplexed (no TLS)"
      "plain TCP, one connection per user"
      "WebSocket, one connection per user"
      "WebSocket + TLS, one connection per user"
      "TCP with Noise encryption (no TLS fingerprint)"
      "KCP over UDP (lossy paths)"
      "QUIC over UDP (TLS 1.3, lossy paths)")
udp_t() { [ "$1" = kcp ] || [ "$1" = quic ]; }
in_use() { if udp_t "$transport"; then ss -Huln "( sport = :$1 )" | grep -q .; else ss -Htln "( sport = :$1 )" | grep -q .; fi; }
tcp_in_use() { ss -Htln "( sport = :$1 )" | grep -q .; }
who() { ss -Htulnp "( sport = :$1 )" 2>/dev/null | grep -o 'users:(("[^"]*"' | head -1 | cut -d'"' -f2; }
lport() { local m=${1%%=*}; echo "${m##*:}"; }
valid_port() { [[ "$1" =~ ^[0-9]+$ ]] && [ "$1" -ge 1 ] && [ "$1" -le 65535 ]; }

echo; echo "$(c '1;33' 'HoneyWeb Tunnel') - Iran (entry) server setup"; echo

# 1. transport
if [ -z "$transport" ]; then
  echo "Transport (how this server and the foreign server talk):"
  for i in "${!TRANSPORTS[@]}"; do printf '  %d) %-8s %s\n' $((i + 1)) "${TRANSPORTS[$i]}" "${DESC[$i]}"; done
  while :; do ask "Choose 1-${#TRANSPORTS[@]}" 1
    [[ "$REPLY" =~ ^[0-9]+$ ]] && [ "$REPLY" -ge 1 ] && [ "$REPLY" -le ${#TRANSPORTS[@]} ] && { transport=${TRANSPORTS[$((REPLY - 1))]}; break; }
    printf '%s %s\n' "$(c 31 '!')" "enter a number from the list"; tty_ok || die "bad transport"; done
fi
printf '%s\n' "${TRANSPORTS[@]}" | grep -qx "$transport" || die "unknown transport '$transport' (one of: ${TRANSPORTS[*]})"

# 2. tunnel port
case "$transport" in tcp|tcpmux|stealth) def=8090;; kcp|quic) def=9443;; *) def=9090;; esac
while :; do
  [ -n "$tport" ] || { ask "Tunnel port (the foreign server connects to this port$(udp_t "$transport" && echo ', UDP'))" "$def"; tport=$REPLY; }
  if ! valid_port "$tport"; then echo "$(c 31 '!') not a port number"
  elif in_use "$tport"; then echo "$(c 31 '!') port $tport is already in use by $(who "$tport")"
  else break; fi
  tty_ok || die "tunnel port $tport is not usable"; tport=""
done

# 3. user ports
while :; do
  [ -n "$ports" ] || { ask "User ports (users connect here; e.g. 443  or  443,8443  or  443=8443 to send 443 to 8443 abroad)" ""; ports=$REPLY; }
  ok=1; IFS=, read -ra pl <<<"${ports// /}"
  [ ${#pl[@]} -gt 0 ] || ok=0
  for m in "${pl[@]}"; do
    [[ "$m" =~ ^([0-9.]+:)?[0-9]+(-[0-9]+)?(=([0-9.]+:)?[0-9]+(-[0-9]+)?)?$ ]] || { echo "$(c 31 '!') '$m' is not PORT or PORT=TARGET"; ok=0; break; }
    p=$(lport "$m"); p=${p%%-*}
    valid_port "$p" || { echo "$(c 31 '!') '$m': bad port"; ok=0; break; }
    { [ "$p" = "$tport" ] && ! udp_t "$transport"; } && { echo "$(c 31 '!') $p is the tunnel port"; ok=0; break; }
    tcp_in_use "$p" && { echo "$(c 31 '!') port $p is already in use by $(who "$p")"; ok=0; break; }
  done
  [ $ok = 1 ] && { ports=$(IFS=,; echo "${pl[*]}"); break; }
  tty_ok || die "user ports '$ports' are not usable"; ports=""
done

# 4. this server's public address (what the foreign server dials)
if [ -z "$pubip" ]; then
  det=$( (ip -4 route get 1.1.1.1 2>/dev/null || true) | awk '{for(i=1;i<=NF;i++) if($i=="src") print $(i+1)}' | head -1)
  case "$det" in 10.*|192.168.*|172.1[6-9].*|172.2[0-9].*|172.3[01].*|100.6[4-9].*|"")
    det=$(curl -fs4 --max-time 5 https://api.ipify.org 2>/dev/null || curl -fs4 --max-time 5 https://ifconfig.me 2>/dev/null || echo "$det")
    [[ "$det" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || det="";; esac
  ask "Public IP of this server (the foreign server connects to it)" "$det"; pubip=$REPLY
fi
[[ "$pubip" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$|^[A-Za-z0-9.-]+\.[A-Za-z]{2,}$ ]] || die "bad public address '$pubip'"

# 5. optional firewall: the tunnel port only from the foreign server
if [ -z "$allow" ] && [ $yes = 0 ]; then
  hint=""; case "$transport" in tcp|tcpmux|ws|wsmux) hint=" (recommended: $transport is not encrypted)";; esac
  ask "Foreign server IP, to accept the tunnel port only from it$hint; Enter to skip" ""; allow=$REPLY
fi
[ -z "$allow" ] || [[ "$allow" =~ ^[0-9]{1,3}(\.[0-9]{1,3}){3}$ ]] || die "bad foreign server IP '$allow'"
[ -z "$allow" ] || command -v nft >/dev/null || die "nft (nftables) is needed for the firewall option: apt install nftables, or skip it"

# Capacity of the foreign side, carried in the link (users at the same time = pool x 8 on mux transports).
[ -n "$pool" ] || case "$transport" in wssmux) pool=896;; tcpmux|wsmux) pool=512;; *) pool=64;; esac
[[ "$pool" =~ ^[0-9]+$ ]] && [ "$pool" -ge 8 ] && [ "$pool" -le 8192 ] || die "--pool must be 8..8192"

# 6. name
if [ -z "$name" ]; then name=$transport; i=2
  while [ -e "/opt/hwtunnel/etc/$name.toml" ] || [ -e "/etc/systemd/system/hwtunnel-$name.service" ]; do name="$transport-$i"; i=$((i + 1)); done; fi

echo
echo "  transport    $(c 1 "$transport")"
echo "  tunnel port  $(c 1 "$pubip:$tport")$(udp_t "$transport" && echo ' (udp)')"
echo "  user ports   $(c 1 "$ports")"
echo "  firewall     $([ -n "$allow" ] && echo "tunnel port only from $allow" || echo 'not changed')"
case "$transport" in tcpmux|wsmux|wssmux) echo "  capacity     pool $pool = $((pool * 8)) users at the same time";; *) echo "  capacity     pool $pool";; esac
echo "  name         hwtunnel-$name"
if [ $yes = 0 ]; then ask "Install? (y/n)" y; [[ "$REPLY" =~ ^[Yy] ]] || { echo "nothing changed"; exit 0; }; fi

fetch_release
token=$(head -c 32 /dev/urandom | od -An -tx1 | tr -d ' \n')
(umask 077; printf '%s\n' "$token" > "$WORK/token")
args=(server --transport "$transport" --tunnel-port "$tport" --port "$ports" --name "$name" --binary "$BINARY" "${VERARGS[@]}" --token-file "$WORK/token")
[ -n "$allow" ] && args+=(--allow-from "$allow")
bash "$WORK/install.sh" "${args[@]}"

payload="1|$transport|$pubip|$tport|$ports|$name|$token|$pool"
sum=$(printf '%s' "$payload" | sha256sum | cut -c1-12)
link="hwt://$(printf '%s|%s' "$payload" "$sum" | base64 -w0 | tr '+/' '-_' | tr -d '=')"
url="https://github.com/$REPO/releases/latest/download/kharej.sh"
echo
echo "$(c '1;32' 'Done.') Iran side is up. Setup link for the foreign server:"
echo
echo "  $link"
echo
echo "On the foreign server (as root) run this ONE command; it installs and connects by itself:"
echo
echo "  bash <(curl -fsSL $url) $link"
echo
echo "$(c 33 'Keep the link private: it contains the tunnel token.')"
