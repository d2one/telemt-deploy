# telemt — MTProto proxy deployment template

A reusable, config-driven deployment for [telemt](https://github.com/telemt/telemt)
(MTProto proxy) in TLS mode, with a masking storefront, an optional Shadowsocks
egress chain for censored networks, and a hidden [telemt_panel](https://github.com/amirotin/telemt_panel)
admin UI. **One** deploy folder serves any number of hosts: each host is described
by a single instance file, and all configs are generated from it.

Two example roles:

| Instance | `EGRESS` | Role |
|----------|----------|------|
| `instances/direct.env`  | `direct`  | Reaches Telegram directly (host on a non-censored network) |
| `instances/chained.env` | `chained` | Behind censorship — routes Telegram DC traffic through a Shadowsocks exit on the direct host |

## Why "chained"

A censoring network (e.g. RU) blocks Telegram's DC ranges, and its DPI drops even
a plain SOCKS5 tunnel because the destination IP is sent in cleartext. So a
`chained` host routes its DC connections through a **Shadowsocks** exit on a
`direct` host ([`exit-shadowsocks/`](exit-shadowsocks)), which encrypts the
destination address.

## Traffic flow

Everything a client touches arrives on `:443`; **telemt** multiplexes it — a valid
faketls proxy secret is relayed to Telegram, anything else is fronted to the masking
storefront. What happens on `:443`, per host:

```
  client :443  (faketls, SNI = your domain)
       │
       ▼
  ┌────────────────────────────┐   chained host only: a per-IP nftables SYN limiter
  │ telemt  (:443, net=host)   │   (1/s/IP) staggers Telegram's first connection
  └──┬──────────────────────┬──┘   burst to dodge RU-TSPU throttling
     │ valid faketls         │ anything else (browser, scanner):
     │ secret  → PROXY       │ TLS-fronting → mask relay
     ▼                       ▼
  Telegram DC          ┌─────────────────────────────────────────┐
  (egress below)       │ nginx :8443   storefront, real LE cert    │
                       └────┬────────────────────────┬─────────────┘
                        path "/"               path "/<secret>/"
                        static site            + HTTP basic-auth
                                                       │
                                                       ▼
                                       ┌──────────────────────────────────┐
                                       │ telemt-panel :8080                │
                                       │ sni-net bridge — NOT on any host  │
                                       │ interface (a port scan can't see  │
                                       │ it)                               │
                                       └─────────────────┬─────────────────┘
                                                         │ host.docker.internal:9091
                                                         │ Authorization: Bearer <API_TOKEN>
                                                         ▼
                                          telemt API :9091  (whitelist
                                          127/8 + docker subnet, token-gated)
```

Egress to Telegram, decided by `EGRESS`:

```
  direct    telemt ───────────────── direct TCP ────────────────▶ Telegram DC
  chained   telemt ── ss:// (encrypts destination) ──▶ direct host's
            Shadowsocks exit (exit-shadowsocks/, :<ss-port>) ────▶ Telegram DC
```

Three kinds of traffic on `:443`: a **proxy client** (faketls secret) → Telegram;
a **browser/scanner** (plain TLS) → nginx storefront (`/` static site, `/<secret>/`
→ basic-auth → panel); telemt's own **mask-fetch** (real TLS-record lengths) →
local nginx (scoped `mask`, off the tunnel on chained).

## Layout

```
Makefile             lifecycle entrypoint — run `make <target> HOST=<instance>` here
deploy/              deployment internals (one set for every host)
  docker-compose.yml   generic (telemt + nginx + certbot + telemt-panel)
  render.sh            instances/<host>.env → deploy/.generated/<host>/* configs
  init-certs.sh        first-time TLS bootstrap
  templates/           nginx.conf.tmpl
  nginx/html/          masking storefront (replace with your own)
instances/           one file per host — ALL per-host values + secrets
  example.env          template; copy to <host>.env (gitignored)
common/              shared Docker build assets + update-telemt.sh + systemd units
exit-shadowsocks/    Shadowsocks egress (runs on the direct host, used by chained)
```

Each host runs exactly one instance; the compose project name is pinned (`telemt`),
so containers/volumes survive path changes.

## How it works

`telemt.toml`, `nginx.conf`, `panel.toml`, `nginx/.htpasswd` and certbot's
`regru.ini` are **generated** — never hand-edited. `render.sh` reads
`instances/<host>.env` and writes them to `deploy/.generated/<host>/` (gitignored),
which docker compose mounts. `EGRESS=direct|chained` toggles the Shadowsocks
upstream and the SYN limiter. So one instance file is the single source of truth
for a host, and the only place secrets live.

## First-time setup

Run everything from the project root.

```sh
cp instances/example.env instances/myhost.env   # then edit it
```

Fill in `instances/myhost.env` — domain, `EGRESS`, proxy users, and the secrets
(commands are in the file's comments):

```sh
openssl rand -hex 16        # each proxy user secret  -> USERS="name:secret ..."
openssl rand -hex 24        # API_TOKEN
openssl rand -hex 11        # PANEL_BASE_PATH (prefix with /)
openssl rand -hex 32        # PANEL_JWT_SECRET
printf '%s' 'ADMINPASS' | docker run --rm -i --entrypoint sh \
  ghcr.io/amirotin/telemt_panel:latest -c 'cat | telemt-panel hash-password'  # PANEL_ADMIN_PASS_HASH
htpasswd -nbB ops 'BASICPASS'    # take the hash after "ops:" -> PANEL_BASIC_PASS_HASH
```

Then bootstrap TLS (public IP must be whitelisted in reg.ru API settings first)
and start everything:

```sh
make init HOST=myhost       # dummy cert → real cert via reg.ru DNS-01
make up   HOST=myhost       # render configs + build + start
```

For a `chained` host, also deploy the Shadowsocks exit on the direct host
(`exit-shadowsocks/`, `cp .env.example .env`) with a matching `SS_PASSWORD`/`SS_PORT`
and the chained host's IP in `ALLOW_IP`; put the same `ss://` URL in `SS_URL`.

## Operating (from the project root, always pass `HOST=`)

```sh
make up      HOST=myhost     # render + build + start
make status  HOST=myhost
make logs-telemt HOST=myhost
make restart HOST=myhost     # re-render + recreate (after editing the instance env)
make update  HOST=myhost     # newer telemt release, with health-check + rollback
make install-timer HOST=myhost   # weekly auto-update via systemd
make cert    HOST=myhost     # (re)issue the TLS cert
```

Set `TELEMT_HOLD=1` in an instance env to pin its `TELEMT_VERSION` (skip auto-update).

## Admin panel (hidden behind the storefront)

[telemt_panel](https://github.com/amirotin/telemt_panel) runs as the `telemt-panel`
service, deployed so a port scan can't find it:

- On the `sni-net` bridge — port `8080` is bound **inside the container only**, on
  no host interface. It reaches the host telemt API via `host.docker.internal:9091`
  (the API whitelists the docker subnet and requires the bearer `API_TOKEN`). No
  docker socket is mounted, so it can manage users via the API but not restart telemt.
- Reached only through nginx, which reverse-proxies the **secret `PANEL_BASE_PATH`**
  to it behind **HTTP basic-auth**. A wrong path returns a generic `401`, never the
  panel's fingerprint. Same domain, cert and `:443` as the storefront — **no extra
  port, no new subdomain, nothing in Certificate Transparency logs.**
- URL: `https://<domain>/<PANEL_BASE_PATH>/` (trailing slash) → basic-auth → panel
  login. `[censorship] mask_relay_*` are raised so panel websockets survive the mask
  relay (storefront path only, not proxying).

## Secrets

This is a **public template** — only `*.example`/templates are committed, with no
real values. Everything secret lives in **`instances/<host>.env`** (gitignored); the
generated configs under `deploy/.generated/` are gitignored too. So a live
deployment and this public repo can share one checkout — the real instance files
and generated configs are never pushed.

| Holds secrets | In git? |
|---------------|---------|
| `instances/<host>.env` | no — `instances/example.env` only |
| `deploy/.generated/<host>/*` (telemt.toml, nginx.conf, panel.toml, .htpasswd, regru.ini) | no |
| `exit-shadowsocks/.env` | no — `.env.example` only |
