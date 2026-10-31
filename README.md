# HoneyWeb Tunnel

A fast, stable reverse tunnel between an entry server (Iran) and an exit server abroad, built in Go and
maintained by HoneyWeb. [فارسی](README_FA.md)

> Based on BackPack by Amin Mohammadi (AminMGMT)
> https://github.com/AminMGMT/BackPack
>
> HoneyWeb Tunnel is a modified version of BackPack, licensed under AGPL-3.0 (see `LICENSE`, `NOTICE`,
> `TRADEMARK.md`). BackPack's data plane is derived from Backhaul by Musixal (AGPL-3.0).

## Install (two commands)

**1. On the Iran (entry) server**, as root:

```bash
bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/iran.sh)
```

The script asks for three things and installs everything else itself:
- **Transport:** how the two servers talk. `wssmux` and `tcpmux` are the HoneyWeb Recommended choices.
- **Tunnel port:** the port on this server that the foreign server connects to.
- **User ports:** the ports users connect to.
  - `443` goes to the same port on the foreign server.
  - `443=8443` goes to port 8443 there.
  - `443,8443` sets several ports at once.

At the end it prints a **setup link** (`hwt://...`) and one command that uses it.

**2. On the foreign (exit) server**, as root, run that command. It asks nothing; it installs and connects by itself:

```bash
bash <(curl -fsSL https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/kharej.sh) hwt://...
```

- The link holds the Iran server's address, the transport, the user ports, the capacity and the token, plus a
  checksum. A link that was cut short in a paste is refused.
- **Capacity defaults** (from HoneyWeb's production peaks): `wssmux` pool 896 (7168 concurrent connections),
  `tcpmux`/`wsmux` 512 (4096). Set your own with `iran.sh --pool N` or `kharej.sh LINK --pool N`.
- **Keep the link private.** It contains the tunnel token.

| Transport | |
|---|---|
| `wssmux` | WebSocket + TLS, multiplexed (Recommended) |
| `tcpmux` | TCP, multiplexed (Recommended) |
| `wsmux` | WebSocket, multiplexed, no TLS |
| `tcp`, `ws`, `wss` | one tunnel connection per user connection |
| `stealth` | TCP with Noise encryption, no TLS fingerprint |
| `kcp`, `quic` | over UDP, for lossy paths |

- **Safety:** a port that is in use is asked again. Existing services and tunnels are never changed.
- **Manage:** `bash iran.sh status`, `bash iran.sh uninstall --name NAME`, `bash iran.sh upgrade`. `kharej.sh` takes the same commands.
- **Private repository:** `export GITHUB_TOKEN=...` first. Alternatively, put the release files in one folder on the server and run `bash iran.sh` from there.
- **Without questions:** `iran.sh --transport wssmux --tunnel-port 9090 --port 443 --yes`.
- **Lower-level installer:** `install.sh server|client ...` (see the top of the file).

## HoneyWeb Recommended

The tuning that carries HoneyWeb's production traffic, chosen for connection quality, plus an explicit
capacity sized for the peak. Details and the evidence behind every value: [honeyweb/RECOMMENDED.md](honeyweb/RECOMMENDED.md).

## Releases

Every release lists the engine commit its binaries are built from and their SHA-256. Builds are reproducible:

```bash
git checkout <engine commit>
CGO_ENABLED=0 GOOS=linux GOARCH=amd64 go build -trimpath -ldflags "-s -w" -o hwtunnel .
sha256sum hwtunnel
```

## Documentation

The engine's full documentation (transports, configuration reference, management tools) is the upstream
documentation in [docs/](docs/) and [docs/upstream/README.md](docs/upstream/README.md).
