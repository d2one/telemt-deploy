# Shadowsocks egress exit

Runs on the **direct host** (`<direct-host-ip>`). The chained front
cannot reach Telegram's data centers directly — the RU network blocks them, and
RU DPI even drops plain SOCKS5 because the destination IP travels in cleartext.
Shadowsocks encrypts the whole stream (including the destination address), so the
hop carries Telegram traffic invisibly.

```
chained telemt  --ss://aes-256-gcm@<direct-host-ip>:<exit-port>-->  this exit  -->  Telegram DC
```

## Deploy

```sh
cp .env.example .env      # set SS_PASSWORD/SS_PORT (must match SS_URL in the chained instance env), ALLOW_IP
docker compose up -d
```

## Lock the port to the front server (important)

The exit port is published on the public interface, so restrict it to the front
server's IP (defense-in-depth on top of the SS key). The systemd unit re-applies
the `DOCKER-USER` allowlist on every boot (Docker recreates that chain):

```sh
sed "s#__EXIT_DIR__#$(pwd)#g" systemd/tg-ss-firewall.service > /etc/systemd/system/tg-ss-firewall.service
systemctl daemon-reload
systemctl enable --now tg-ss-firewall.service
```

`firewall.sh` reads `SS_PORT` and `ALLOW_IP` from `.env`.

## Notes

- Single point of failure: if this exit is down, the chained front cannot reach
  Telegram (the direct host `proxy.example.com` proxy itself is unaffected — it egresses directly).
- The image is `ghcr.io/shadowsocks/ssserver-rust` with `restart: unless-stopped`,
  so it survives reboots on its own.
