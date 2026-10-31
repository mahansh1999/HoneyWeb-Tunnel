# HoneyWeb Tunnel

A fast, stable reverse tunnel between an entry server (Iran) and an exit server abroad, built in Go and
maintained by HoneyWeb. [فارسی](README_FA.md)

> Based on BackPack by Amin Mohammadi (AminMGMT)
> https://github.com/AminMGMT/BackPack
>
> HoneyWeb Tunnel is a modified version of BackPack, licensed under AGPL-3.0 (see `LICENSE`, `NOTICE`,
> `TRADEMARK.md`). BackPack's data plane is derived from Backhaul by Musixal (AGPL-3.0).

## Install

On the entry server (as root):

```bash
curl -fsSLO https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/install.sh
bash install.sh server --transport wssmux --tunnel-port 9090 --port 540
```

The server install prints the exact client command, including the token. On the exit server (as root):

```bash
curl -fsSLO https://github.com/mahansh1999/HoneyWeb-Tunnel/releases/latest/download/install.sh
bash install.sh client --transport wssmux --server ENTRY_IP:9090 --token TOKEN
```

For a private repository set `GITHUB_TOKEN` before running the installer, or copy the release files to the
server and pass `--binary ./hwtunnel-linux-amd64` (the installer verifies it against `SHA256SUMS` next to it).

| Command | What it does |
|---|---|
| `install.sh server ...` / `client ...` | New tunnel with the HoneyWeb Recommended profile. Stops before writing anything if a port is in use or the name exists. |
| `install.sh upgrade` | Replaces the binary only. Configs are never rewritten. |
| `install.sh rollback` | Back to the previous binary. |
| `install.sh status` / `uninstall --name N` | |

Options: `--name`, `--pool N` (client capacity, default 512 sessions = 4096 concurrent connections),
`--allow-from IP` (server: accept the tunnel port only from the client's IP; recommended for `tcpmux`),
`--version TAG`, `--binary FILE`.

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
