# AGENTS.md

This file provides guidance to Codex and other coding agents when working with
this repository.

## Project Overview

Config-driven deployment for telemt (MTProto proxy) in TLS mode, with a masking
storefront, an optional Shadowsocks egress chain, and a hidden telemt_panel admin
UI. **One** `deploy/` folder serves any number of hosts; each host is one instance
file under `instances/`, and all configs are generated from it. See
[README.md](README.md) for the operator-facing overview.

| Instance (`EGRESS`) | Role |
|---------------------|------|
| `instances/<h>.env`, `EGRESS=direct`  | reaches Telegram directly (non-censored host) |
| `instances/<h>.env`, `EGRESS=chained` | censored host; Telegram DC traffic via Shadowsocks exit on a direct host |

## Architecture

Per host, traffic flow: `Client :443` → **telemt** (`network_mode: host`) → either
relays proxy traffic to Telegram, or forwards non-proxy TLS to **nginx:8443**
(the masking storefront). **certbot** issues/renews the Let's Encrypt cert via the
`certbot-regru` DNS-01 plugin.

**`EGRESS=chained` is the key difference.** RU blocks Telegram's DC ranges, and RU
DPI drops plain SOCKS5 because the destination IP is cleartext in the CONNECT.
So a chained host routes DC connections through a **Shadowsocks** upstream on a
direct host (`exit-shadowsocks/`), which encrypts the destination. For `chained`,
`render.sh` emits into the generated `telemt.toml`: `tls_fetch_scope="mask"`, a
`direct` upstream scoped `"mask"` (keeps the mask fetch/relay off the tunnel), a
`shadowsocks` upstream (catches DC connections, scope=None), and the SYN limiter.
`EGRESS=direct` omits the Shadowsocks chain and reaches Telegram directly; it only
gets the SYN limiter when explicitly opted in with `SYNLIMIT=1`.

## Repo layout

```
Makefile           lifecycle entrypoint — run `make <target> HOST=<instance>` from the project root
deploy/            docker-compose.yml, render.sh, init-certs.sh, templates/, nginx/html/
instances/         <host>.env — ALL per-host values + secrets (example.env committed)
common/            Dockerfile, certbot.Dockerfile, panel.Dockerfile, update-telemt.sh, systemd templates
exit-shadowsocks/  Shadowsocks egress (deployed on a direct host, used by chained)
```

**Config is generated, never hand-edited.** `deploy/render.sh <host>` reads
`instances/<host>.env` and writes `deploy/.generated/<host>/{telemt.toml, nginx.conf,
panel.toml, .htpasswd, regru.ini}` (gitignored), which compose mounts. The single
instance env is the source of truth and the only place secrets live. Operate from
the **project root** and always pass `HOST=<instance>` (the root `Makefile` renders,
`cd`s into `deploy/`, sources the env so compose can interpolate
`${HOST}`/`${*_VERSION}`, then runs compose). `name: telemt`
is pinned so containers/volumes survive. Each server runs exactly one instance.

## Admin panel (telemt_panel) — hidden behind the storefront

Each host runs [telemt_panel](https://github.com/amirotin/telemt_panel) as a
`telemt-panel` compose service, deliberately deployed so a port scan can't find it:

- **On the `sni-net` bridge** (NOT host net): binds `8080` inside the container
  only — invisible on every host interface. It reaches the host telemt API via
  `host.docker.internal:9091`; telemt's `[server.api]` whitelists `172.16.0.0/12`
  and requires a bearer `auth_header` token (`API_TOKEN` in the instance env —
  rendered into both `telemt.toml` and `panel.toml`). No docker socket mounted →
  panel can't restart telemt (smaller blast radius).
- **Reached only via nginx**, which reverse-proxies the secret `PANEL_BASE_PATH`
  to `telemt-panel:8080` behind **HTTP basic-auth** (`PANEL_BASIC_*` → generated
  `.htpasswd`, user `ops`). Wrong path → generic `401`, no panel fingerprint. Served
  on the existing storefront `:443`/cert → no new port, no new subdomain, **no
  CT-log leak**. Browser URL: `https://<domain>/<PANEL_BASE_PATH>/` (trailing slash).
- `nginx.conf.tmpl` carries the `map $http_upgrade $connection_upgrade` +
  `limit_req_zone` at `http{}` and a `resolver 127.0.0.11` + variable `proxy_pass`
  in the panel location (so nginx starts even if the panel is briefly down).
  `[censorship] mask_relay_timeout_ms=1800000` / `mask_relay_idle_timeout_ms=60000`
  (always rendered) keep panel websockets alive through the mask relay (storefront
  path only, not proxying).
- All panel values/secrets live in `instances/<host>.env`; `render.sh` produces
  `panel.toml` + `.htpasswd`. Pinned by `PANEL_VERSION`; built from `common/panel.Dockerfile`.
- After editing an instance env, `make restart HOST=<h>` re-renders and recreates
  everything (API token/whitelist + mask timeouts are not hot-reload, so telemt must
  restart; the `.htpasswd`/`nginx.conf` changes need an nginx recreate too).

## Common commands (run from the project root, always with `HOST=<instance>`)

| Command | Description |
|---------|-------------|
| `make up` / `down` / `restart` / `build` | Lifecycle (render + compose) |
| `make logs` / `logs-telemt` / `logs-panel` / `status` | Inspect |
| `make clean` | Stop and remove volumes |
| `make cert` / `cert-renew` | Issue / renew the TLS cert (domain from instance env) |
| `make update` | Apply a newer telemt release (bump version in instance env, rebuild, auto-rollback) |
| `make install-timer` / `uninstall-timer` | Weekly auto-update systemd timer (bakes `HOST`) |

First-time TLS bootstrap on a fresh host: `make init HOST=<instance>` (wraps
`deploy/init-certs.sh`). The host's public IP must first be whitelisted in the reg.ru
API settings. Requires `jq`+`curl` on the host for auto-update.

**Version hold:** `TELEMT_HOLD=1` in an instance env makes `update-telemt.sh <host>`
skip auto-update (pin `TELEMT_VERSION`). Set it when a release is known-broken for
that host; verify SS-relay health after any update by the startup *DC Connectivity*
table (`via shadowsocks://…`, DCs reachable), NOT by `update-telemt.sh`'s health
check, which only confirms the container is running and would pass a broken relay.
NB: floods of `Telegram handshake timeout` are **RU-side DPI** dropping
the client's faketls ClientHello in transit (tcpdump: client completes TCP but sends
no data; server never receives it), not a server/version bug. The server side stays
healthy (DCs reachable, raw MTProto probe gets `resPQ`).

**Slow / failed connect = TSPU burst-throttling — fixed by per-IP SYN rate-limit.**
Symptom: android "stuck on connecting" for minutes, or not connecting at all. Root
cause: Telegram opens a **burst** of connections on first connect; TSPU flags the
burst to one IP and drops ~half the faketls handshakes in transit → endless client
retries. **The fix is a per-IP new-connection rate-limit** (≈1 accepted SYN/sec/IP)
that staggers the burst so each handshake gets through.

This uses **telemt's built-in per-listener SYN limiter** (telemt ≥ 3.4.17).
`render.sh` emits it for every `EGRESS=chained` host, and for `EGRESS=direct` only
when the instance opts in with `SYNLIMIT=1`. The generated `telemt.toml`
`[[server.listeners]]` defaults are `synlimit_seconds=60`,
`synlimit_hitcount=48`, `synlimit_burst=1`, plus the iOS bucket
`synlimit_ios_seconds=1`, `synlimit_ios_hitcount=12`,
`synlimit_ios_burst=24`; override them per host with `SYNLIMIT_SECONDS`,
`SYNLIMIT_HITCOUNT`, `SYNLIMIT_BURST`, `SYNLIMIT_IOS_SECONDS`,
`SYNLIMIT_IOS_HITCOUNT`, and `SYNLIMIT_IOS_BURST`. For harsher TSPU bursts,
set both buckets toward `1/1/1`. telemt installs/reconciles the rule itself (its
own isolated nft table — off iptables) and removes it on graceful shutdown. Needs
`network_mode: host` + `NET_ADMIN` (compose grants `NET_ADMIN` to telemt on every
host) and the `nftables`/`iptables` binaries the image ships
(`common/Dockerfile`). Confirm: `nft list ruleset | grep -iA8 telemt` (drop counter
rising = staggering). Tune the `SYNLIMIT_*` env values if TSPU still flags the burst.

`EGRESS=direct` without `SYNLIMIT=1` renders no synlimit, so telemt installs
nothing; because compose still grants `NET_ADMIN`, the boot-time SYN-table cleanup
succeeds silently (no WARN).

Dead ends ruled out along the way (don't re-chase): `client_mss="tspu"` MSS-92
fragmentation did nothing; the "low-reputation SNI" theory was wrong — switching
`tls_domain` to a high-rep domain (`ngs.ru`) appeared to help only because each test
restart momentarily broke the burst, and own domain `relay.example.com` works fine once
the rate-limit is in place (so the chained host stays on its own domain + local nginx mask).
A channel report (telemt 3.4.15 on a simple RU VPS, no double-hop) shows the slow
connect is general to 3.4.15 under RU DPI, not our SS/SNI setup.

If you ever DO hit genuine **SNI-based** blocking (ClientHello to a specific domain
dropped even with the rate-limit on), changing the domain is the lever: set a new
`DOMAIN` in the instance env, re-issue the cert (`./init-certs.sh <host>` — `tls_domain`
+ nginx `server_name`/cert all follow `DOMAIN`), then `make restart HOST=<host>`. Also
clear the TLS-front cache (`docker exec telemt rm -f /opt/telemt/tlsfront/*.json` +
restart) or you get `Skipping TLS cache entry with mismatched certificate metadata`
→ no ServerHello → timeout; and hand out new EE links (the domain is hex-encoded in
the secret). Diagnosis: `error=Unknown TLS SNI` → client on a stale link; client bytes
arrive but server silent → stale cache / cert-SNI mismatch.

## Deployment notes

- Each server runs one instance from `deploy/` (compose project `telemt`):
  `make up HOST=<instance>`.
- SS exit: runs on a direct host from `exit-shadowsocks/` (compose project
  `tg-socks-exit`); its `tg-ss-firewall.service` reapplies the port allowlist on boot.

## Secrets

Public template: only `*.example`/templates are committed, with no real values.
Everything secret lives in **`instances/<host>.env`** (gitignored) — proxy user
secrets, `API_TOKEN`, the chained `SS_URL`, panel creds/JWT, basic-auth hash, reg.ru
creds. The configs `render.sh` produces under `deploy/.generated/<host>/` (telemt.toml,
nginx.conf, panel.toml, .htpasswd, regru.ini) and `exit-shadowsocks/.env` are
gitignored too. A live deployment and this public repo can share one checkout — the
instance files and generated configs are never pushed.
