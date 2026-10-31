# HoneyWeb Recommended profile

The settings `honeyweb/install.sh` writes. They are the configuration that has carried HoneyWeb's production
traffic since 2026-10-30, chosen for connection quality (fast handshake, throughput, stability under load),
not for the smallest footprint.

Every key belongs to one of three policies. Changing the performance profile must never change capacity.

## Performance profile (both ends)

| Key | Value | Why |
|---|---|---|
| `nodelay` | `true` | Nagle added a round trip to every small request. |
| `mux_version` | `2` (wssmux only; tcpmux negotiates v2 itself) | smux v1 has no per-stream flow control: one slow user stalled every stream of its session (50 % timeouts in an A/B test). wssmux has no negotiation, so both ends must say 2. |
| `mux_streambuffer` | `2097152` (2 MiB) | A 64 KiB window capped one TCPMUX connection at about 3 Mbit/s over an 80 ms path; 2 MiB measured 149-169 Mbit/s. |
| `mux_recievebuffer` | `16777216` (16 MiB) | Session window for 8 streams of 2 MiB. |

## Capacity policy

| Key | Side | Value | Why |
|---|---|---|---|
| `connection_pool` | client | `896` for wssmux, `512` for tcpmux/wsmux by default (`--pool`) | Concurrent user connections are capped at `connection_pool x mux_con`. With 16 MiB buffers the pool never grows past its configured size, so it must be sized for the peak. |
| `mux_con` | server | `8` (written explicitly) | Streams per session. |

**Sizing rule:** `connection_pool >= ceil(2 x peak concurrent connections / 8)`. Count the peak at the busiest
hour and count idle client connections too: about half of all streams are idle connections that clients keep
open, and each one holds a slot until it is closed. HoneyWeb production runs 896 (WSSMUX) and 384 (TCPMUX).

Never switch these tunnels to a BackPack wizard/panel preset: those presets overwrite `connection_pool` and
`mux_con` (Turbo writes pool 8, i.e. 64 streams).

## Infrastructure policy

| Key / setting | Value | Why |
|---|---|---|
| `skip_optz` | `true` | The engine must not rewrite host sysctl values shared with other services. |
| `log_level` | `info` | |
| Unit | `User=hwtunnel`, `NoNewPrivileges`, `ProtectSystem=strict`, `LimitNOFILE=1048576`, `CAP_NET_BIND_SERVICE` only for ports below 1024 | Least privilege. |
| `RuntimeDirectory=backpack` + `RuntimeDirectoryPreserve=yes` | | Several tunnels share `/run/backpack` for their control sockets; stopping one must not remove the others'. |
| `--allow-from IP` (server, optional) | nftables table `inet hwtunnel_<name>` | Recommended for tcpmux, whose token travels in plain text: accept the tunnel port only from the client's IP. |
| TLS (wssmux) | self-signed EC P-256, 10 years | The engine authenticates with channel binding and the token, not with PKI. |

## Other transports

The installer also sets up `wsmux`, `tcp`, `ws`, `wss`, `stealth`, `kcp` and `quic`. Only `wssmux` and `tcpmux`
carry HoneyWeb's production traffic. The others are tested in the lab only: all nine were installed side by side
through `iran.sh` and `kharej.sh` on two fresh servers with an 80 ms RTT, and 100/100 TLS handshakes went
through each one.

| Family | Transports | What is written |
|---|---|---|
| mux | `tcpmux`, `wsmux`, `wssmux` | The profile above. `mux_version = 2` on `wsmux`/`wssmux`. `connection_pool` default 896 (wssmux) or 512. |
| one connection per user | `tcp`, `ws`, `wss`, `stealth` | `nodelay = true`. `connection_pool` default 64: these are connections kept ready for new users, not a stream limit. |
| UDP | `kcp`, `quic` | The engine's own tuning. `connection_pool` default 64. |

In the lab, a TLS handshake through `kcp` took about two round trips (p50 166 ms against 87 ms for the others).
