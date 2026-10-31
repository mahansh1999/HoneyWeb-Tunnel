#!/usr/bin/env bash
# kharej.sh: HoneyWeb Tunnel setup for the foreign (exit) server. Run as root with the link iran.sh printed:
#
#   bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/kharej.sh) hwt://...
#
# The link (hwt://...) carries the Iran server's address, tunnel port, transport, user ports, capacity and token,
# with a checksum. Nothing is asked: the script checks the link and the path to Iran, installs, and connects.
# Run without a link and it asks for one (paste it).
#
# Options:  kharej.sh LINK [--pool N] [--name NAME]
# Other commands are passed to install.sh: kharej.sh status | uninstall --name N | upgrade | rollback
set -euo pipefail
umask 022
REPO=${HWT_REPO:-mahansh1999/HoneyWeb-Tunnel}
VERSION=${HWT_VERSION:-latest}
die() { echo "kharej.sh: $*" >&2; exit 1; }
c() { printf '[%sm%s[0m' "$1" "$2"; }
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

case "${1:-}" in
  status|uninstall|rollback) fetch_release; rc=0; bash "$WORK/install.sh" "$@" || rc=$?; exit $rc;;
  upgrade) shift; fetch_release; rc=0; bash "$WORK/install.sh" upgrade --binary "$BINARY" "${VERARGS[@]}" "$@" || rc=$?; exit $rc;;
esac

link=""; pool=""; name=""; asked=0
while [ $# -gt 0 ]; do case "$1" in
  hwt://*) link=$1; shift;; --pool) pool=$2; shift 2;; --name) name=$2; shift 2;;
  --yes|-y) shift;; -h|--help) sed -n '2,12p' "$0"; exit 0;; *) die "unknown option $1 (the link starts with hwt://)";; esac; done

echo; echo "$(c '1;33' 'HoneyWeb Tunnel') - foreign (exit) server setup"; echo
while [ -z "$link" ]; do tty_ok || die "give the setup link: kharej.sh hwt://..."
  ask "Paste the setup link from the Iran server (hwt://...)" ""; link=$(printf '%s' "$REPLY" | tr -d ' \r'); asked=1
  [[ "$link" == hwt://* ]] || { echo "$(c 31 '!') the link starts with hwt://"; link=""; }; done
[[ "$link" =~ ^hwt://[A-Za-z0-9_-]+$ ]] || die "this is not a HoneyWeb Tunnel setup link"
b=${link#hwt://}; b=$(printf '%s' "$b" | tr -- '-_' '+/'); while [ $(( ${#b} % 4 )) != 0 ]; do b="$b="; done
dec=$(printf '%s' "$b" | base64 -d 2>/dev/null) || die "the link is damaged: copy the whole link again"
IFS='|' read -r ver transport entry tport ports iname token lpool sum <<<"$dec"
[ "${ver:-}" = 1 ] || die "the link is damaged or from a newer version: copy the whole link again"
[ "$(printf '%s' "${dec%|*}" | sha256sum | cut -c1-12)" = "${sum:-}" ] || die "the link is damaged (checksum): copy the whole link again"
[[ "$transport" =~ ^(wssmux|tcpmux|wsmux|tcp|ws|wss|stealth|kcp|quic)$ ]] || die "the link names an unknown transport"
[[ "$entry" =~ ^[A-Za-z0-9.-]+$ && "$tport" =~ ^[0-9]+$ && "$token" =~ ^[0-9a-f]{64}$ && "$iname" =~ ^[a-z0-9][a-z0-9-]{0,30}$ ]] || die "the link is damaged"
[[ "$ports" =~ ^[0-9.:=,-]+$ && "$lpool" =~ ^[0-9]+$ ]] || die "the link is damaged"
udp_t() { [ "$transport" = kcp ] || [ "$transport" = quic ]; }
mux_t() { case "$transport" in tcpmux|wsmux|wssmux) return 0;; esac; return 1; }
pool=${pool:-$lpool}
[[ "$pool" =~ ^[0-9]+$ ]] && [ "$pool" -ge 8 ] && [ "$pool" -le 8192 ] || die "pool must be 8..8192"

echo "  Iran server  $(c 1 "$entry:$tport")$(udp_t && echo ' (udp)')"
echo "  transport    $(c 1 "$transport")"
if mux_t; then echo "  capacity     pool $pool = $((pool * 8)) users at the same time"; else echo "  capacity     pool $pool"; fi
# Where each user port ends up on this server, and whether something listens there.
IFS=, read -ra pl <<<"$ports"; miss=0
for m in "${pl[@]}"; do
  t=${m#*=}; [ "$t" = "$m" ] && t=${m##*:}
  th=127.0.0.1; [[ "$t" == *:* ]] && { th=${t%:*}; t=${t##*:}; }
  t1=${t%%-*}
  if [ "$th" = 127.0.0.1 ] && ! ss -Htln "( sport = :$t1 )" | grep -q .; then
    echo "  user port    ${m%%=*} -> $th:$t   $(c 33 'nothing listens there yet (start the service behind it)')"; miss=1
  else echo "  user port    ${m%%=*} -> $th:$t   $(c 32 ok)"; fi
done

# The path to Iran (TCP transports only: UDP has no handshake to test). Unreachable: nothing is installed.
if ! udp_t; then
  if timeout 6 bash -c "exec 3<>/dev/tcp/$entry/$tport" 2>/dev/null; then echo "  path to Iran $(c 32 'open')"
  else echo "  path to Iran $(c 31 "no answer from $entry:$tport")"
    echo "               check that iran.sh finished on the Iran server and that no firewall blocks this server"
    if [ $asked = 1 ]; then ask "Install anyway? (y/n)" n; [[ "$REPLY" =~ ^[Yy] ]] || exit 1; else die "Iran server not reachable; nothing changed"; fi
  fi
fi

[ -n "$name" ] || { name=$iname; i=2
  while [ -e "/opt/hwtunnel/etc/$name.toml" ] || [ -e "/etc/systemd/system/hwtunnel-$name.service" ]; do name="$iname-$i"; i=$((i + 1)); done; }

fetch_release
(umask 077; printf '%s\n' "$token" > "$WORK/token")
bash "$WORK/install.sh" client --transport "$transport" --server "$entry:$tport" --name "$name" --pool "$pool" \
  --binary "$BINARY" "${VERARGS[@]}" --token-file "$WORK/token"
echo
echo "$(c '1;32' 'Done.') This server is connected to Iran ($entry:$tport, $transport)."
[ $miss = 0 ] || echo "$(c 33 'Note:') start the service behind the user ports above; the tunnel delivers users to it."
echo "Status: bash kharej.sh status    Remove: bash kharej.sh uninstall --name $name"
