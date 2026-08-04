# telemt deploy — run from the PROJECT ROOT, pick an instance with HOST=<name>:
#   make up HOST=chained        # render instances/chained.env -> configs, then up
# Every per-host value/secret lives in instances/<HOST>.env; configs are generated
# into deploy/.generated/<HOST>/ and mounted by deploy/docker-compose.yml.
.PHONY: require-host render build up down restart logs logs-nginx logs-telemt logs-panel \
        status clean init cert cert-renew update install-timer uninstall-timer

ROOT   := $(CURDIR)
DEPLOY := $(ROOT)/deploy
COMMON := $(ROOT)/common
ENVF   := $(ROOT)/instances/$(HOST).env

# cd into deploy/ (compose file + its relative paths live there), source the
# instance env (exports HOST/TELEMT_VERSION/PANEL_VERSION for interpolation), then
# run docker compose. Single line so it works as one recipe shell.
COMPOSE = cd $(DEPLOY) && set -a; . "$(ENVF)"; set +a; HOST=$(HOST) docker compose

require-host:
	@test -n "$(HOST)" || { echo "Set HOST=<instance>, e.g. make up HOST=chained"; exit 1; }
	@test -f "$(ENVF)"  || { echo "No instance file: $(ENVF) (copy instances/example.env)"; exit 1; }

render: require-host
	@$(DEPLOY)/render.sh $(HOST)

build: render
	@$(COMPOSE) build
up: render
	@$(COMPOSE) up -d
restart: render
	@$(COMPOSE) up -d --force-recreate
down: require-host
	@$(COMPOSE) down
logs: require-host
	@$(COMPOSE) logs -f
logs-nginx: require-host
	@$(COMPOSE) logs -f nginx
logs-telemt: require-host
	@$(COMPOSE) logs -f telemt
logs-panel: require-host
	@$(COMPOSE) logs -f telemt-panel
status: require-host
	@$(COMPOSE) ps
clean: require-host
	@$(COMPOSE) down -v

init: require-host
	@$(DEPLOY)/init-certs.sh $(HOST)

cert: render
	@$(COMPOSE) run --rm --entrypoint "" certbot \
		certbot certonly -a dns -d "$$DOMAIN" --agree-tos --no-eff-email --email "$$CERT_EMAIL" -n \
			--dns-propagation-seconds 300
	@$(COMPOSE) restart nginx
cert-renew: require-host
	@$(COMPOSE) run --rm --entrypoint "" certbot certbot renew
	@$(COMPOSE) restart nginx

update: require-host
	@$(COMMON)/update-telemt.sh $(HOST)

install-timer: require-host
	sed -e 's#__DEPLOY_DIR__#$(DEPLOY)#g' -e 's#__COMMON_DIR__#$(COMMON)#g' -e 's#__HOST__#$(HOST)#g' \
		$(COMMON)/systemd/telemt-update.service > /etc/systemd/system/telemt-update.service
	cp $(COMMON)/systemd/telemt-update.timer /etc/systemd/system/
	systemctl daemon-reload
	systemctl enable --now telemt-update.timer
	systemctl list-timers telemt-update.timer
uninstall-timer:
	systemctl disable --now telemt-update.timer
	rm -f /etc/systemd/system/telemt-update.service /etc/systemd/system/telemt-update.timer
	systemctl daemon-reload
