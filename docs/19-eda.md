# Lab 19 — Event-Driven Ansible (eda-server from source)

## What you will have at the end

Event-Driven Ansible — **eda-server** — built from source, running as its systemd
service family (API, websockets, scheduler, worker), fronted by its own nginx, and
registered behind the gateway so `https://192.168.56.10/api/eda/…` authenticates
with the same platform login as the controller and the hub.

```
envoy :443 ──/api/eda/…──► nginx :8445 ──┬── unix:/run/eda/eda-api.sock   (gunicorn, aap_eda.wsgi — REST API)
   (gateway JWT)                           └── unix:/run/eda/eda-ws.sock    (daphne, aap_eda.asgi — websockets)
                                           aap-eda-manage scheduler         (periodic)
                                           aap-eda-manage dispatcherd       (DefaultWorker — pg_notify tasking, like AWX)
```

> **The good news up front:** after the hub's version-alignment saga ([Lab 18](18-hub.md)),
> EDA is a relief. `eda-server`'s `main` pins **django-ansible-base from git devel** — the
> *same* DAB the gateway (jewel-devel) uses — so JWT single sign-on lines up on the first try.
> Track `main`, not a stable branch, for exactly this reason.

All commands on **ace-control**.

## Foundation

```bash
sudo useradd --system --home-dir /var/lib/eda --create-home --shell /bin/bash eda
sudo install -d -o eda -g eda /var/lib/eda /var/lib/eda/media /var/lib/eda/static /etc/eda
sudo usermod -aG redis eda

sudo -iu postgres psql -c "CREATE USER eda WITH PASSWORD 'CHANGE-ME';"
sudo -iu postgres psql -c "CREATE DATABASE eda OWNER eda;"
```

## Clone and build

`eda-server` is a poetry project, but a plain `pip install .` reads its `pyproject.toml`
and resolves everything (DAB devel, Django 5.2, channels/daphne, dispatcherd):

```bash
sudo install -d -o eda -g eda /opt/eda-server
sudo -u eda git clone https://github.com/ansible/eda-server.git /opt/eda-server
sudo -u eda git -C /opt/eda-server rev-parse --short HEAD    # RECORD THIS — moving tip

sudo -u eda python3.12 -m venv /var/lib/eda/venv
sudo -u eda bash <<'EOF'
set -euo pipefail
source /var/lib/eda/venv/bin/activate
pip install --upgrade pip setuptools wheel
cd /opt/eda-server
pip install . gunicorn
# EDA shells out to these three at *import time* and at runtime — they must be in the venv:
pip install ansible-runner ansible-core ansible-rulebook
pip list | grep -iE 'aap-eda|django-ansible-base|django |channels|daphne'  # RECORD
EOF
```

> **Why the three extra `pip install`s.** eda-server imports helpers that call
> `shutil.which(...)` for external executables *as their modules load* — miss them and even
> `migrate` dies with `ExecutableNotFoundError: Cannot find ansible-runner executable`
> (then `ansible-vault`, from ansible-core; then `ansible-rulebook` for activations). They
> aren't in eda-server's own dependency set because a packaged install delivers them as
> sibling packages; from source, you install them yourself.

The PATH wrapper — `aap-eda-manage`, carrying `EDA_SETTINGS_FILE`, `OPENSSL_armcap=0`
(same Apple-Silicon SIGILL as the gateway/hub), and a **venv-first `PATH`** so those
`shutil.which` lookups resolve inside the exec'd process:

```bash
sudo tee /usr/bin/aap-eda-manage >/dev/null <<'EOF'
#!/bin/bash
export OPENSSL_armcap=0
export EDA_SETTINGS_FILE=/etc/eda/settings.yaml
export PATH=/var/lib/eda/venv/bin:$PATH
exec /var/lib/eda/venv/bin/aap-eda-manage "$@"
EOF
sudo chmod 0755 /usr/bin/aap-eda-manage
```

## Settings — `/etc/eda/settings.yaml`

eda-server reads a dynaconf YAML (`EDA_SETTINGS_FILE`, defaulting to `/etc/eda/settings.yaml`):

```bash
sudo -u eda bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/eda/SECRET_KEY'
sudo chmod 0400 /etc/eda/SECRET_KEY

sudo tee /etc/eda/settings.yaml >/dev/null <<'EOF'
SECRET_KEY_FILE: /etc/eda/SECRET_KEY
ALLOWED_HOSTS: "*"
DATABASES:
  default:
    ENGINE: django.db.backends.postgresql
    NAME: eda
    USER: eda
    PASSWORD: CHANGE-ME
    HOST: localhost
    PORT: 5432
MEDIA_ROOT: /var/lib/eda/media
STATIC_ROOT: /var/lib/eda/static
STATIC_URL: /api/eda/static/
DEPLOYMENT_TYPE: podman
MQ_HOST: localhost
MQ_PORT: 6379
MQ_DB: 5
# gateway integration (JWT consumer)
ANSIBLE_BASE_JWT_KEY: https://192.168.56.10
ANSIBLE_BASE_JWT_VALIDATE_CERT: false
ANSIBLE_BASE_JWT_REDIRECT_TYPE: eda
ANSIBLE_BASE_MANAGED_ROLE_REGISTRY:
  platform_auditor:
    name: Platform Auditor
    shortname: sys_auditor
ENABLE_SERVICE_BACKED_SSO: false
WEBSOCKET_BASE_URL: wss://192.168.56.10
WEBSOCKET_SSL_VERIFY: "no"
EOF
sudo chown eda:eda /etc/eda/settings.yaml
sudo chmod 0640 /etc/eda/settings.yaml
sudo vim /etc/eda/settings.yaml    # set the real DB password
```

## Redis: a loopback TCP listener

EDA addresses redis by **host:port** (for the channels/websocket layer), but Lab 5's redis is
**socket-only** (`port 0`). Add a loopback TCP listener *alongside* the socket — the socket
stays for the controller and hub, EDA gets its port:

```bash
sudo sed -i 's/^port 0/port 6379\nbind 127.0.0.1 -::1/' /etc/redis/redis.conf
sudo systemctl restart redis
sudo -u awx redis-cli -s /var/run/redis/redis.sock ping    # want: PONG — socket still works
```

## Migrate, init, admin, static

```bash
sudo -u eda aap-eda-manage migrate                    # want: long OK run
sudo -u eda aap-eda-manage create_initial_data        # seeds roles/permissions
sudo -u eda bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-eda-manage createsuperuser --username admin --email admin@example.com --noinput'
sudo -u eda bash -c 'umask 022 && aap-eda-manage collectstatic --noinput --clear'
```

> `migrate` logs `RESOURCE_SERVER['SECRET_KEY'] is not configured. Reverse sync will not be
> enabled.` — expected. We add the secret when we wire the gateway, at the end of this lab.

## The service family (systemd)

Four units, one shared environment file. The workers use **dispatcherd** over pg_notify —
the same task engine as the controller (Lab 11), no separate broker:

```bash
sudo tee /etc/tmpfiles.d/eda.conf >/dev/null <<'EOF'
d /run/eda 0755 eda eda -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/eda.conf

sudo tee /etc/default/eda >/dev/null <<'EOF'
OPENSSL_armcap=0
EDA_SETTINGS_FILE=/etc/eda/settings.yaml
PATH=/var/lib/eda/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
EOF

VENV=/var/lib/eda/venv/bin

sudo tee /etc/systemd/system/automation-eda-api.service >/dev/null <<EOF
[Unit]
Description=EDA API (gunicorn wsgi)
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/eda
User=eda
Group=eda
RuntimeDirectory=eda
ExecStart=${VENV}/gunicorn --name eda-api --bind unix:/run/eda/eda-api.sock --workers 2 aap_eda.wsgi --access-logfile -
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/automation-eda-ws.service >/dev/null <<EOF
[Unit]
Description=EDA websockets (daphne asgi)
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/eda
User=eda
Group=eda
RuntimeDirectory=eda
ExecStart=${VENV}/daphne -u /run/eda/eda-ws.sock aap_eda.asgi:application
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/automation-eda-scheduler.service >/dev/null <<EOF
[Unit]
Description=EDA scheduler
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/eda
User=eda
Group=eda
ExecStart=${VENV}/aap-eda-manage scheduler
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/automation-eda-default-worker.service >/dev/null <<EOF
[Unit]
Description=EDA default worker (dispatcherd)
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/eda
User=eda
Group=eda
ExecStart=${VENV}/aap-eda-manage dispatcherd --worker-class DefaultWorker
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo semanage fcontext -a -t bin_t '/var/lib/eda/venv/bin(/.*)?'   # Lab 11's 203/EXEC fix
sudo restorecon -Rv /var/lib/eda/venv/bin
sudo systemctl daemon-reload
sudo systemctl enable --now automation-eda-api automation-eda-ws automation-eda-scheduler automation-eda-default-worker

curl -s --unix-socket /run/eda/eda-api.sock http://localhost/api/eda/v1/status/ \
  -H 'Host: 192.168.56.10'
# want: {"status": ...} JSON. A momentary "degraded / Dispatcherd workers unavailable"
# right after start is heartbeat lag — `journalctl -u automation-eda-default-worker` will
# show "pg_notify … established" and tasks running.
```

> **Production note:** the full EDA also runs an **ActivationWorker**
> (`aap-eda-manage dispatcherd --worker-class ActivationWorker`), which launches rulebook
> activations as podman containers — the decision-environment equivalent of the controller's
> EEs. Add it as a fifth unit when you want to run activations; the API, scheduler, and
> default worker above are enough to bring EDA up and register it with the platform.

## nginx front on 8445

```bash
sudo ace-sign-service server /etc/ansible-automation-platform/eda eda ace-control cert

sudo tee /etc/nginx/conf.d/automation-eda.nginx.conf >/dev/null <<'EOF'
upstream eda-api { server unix:/run/eda/eda-api.sock; }
upstream eda-ws  { server unix:/run/eda/eda-ws.sock; }
server {
    listen 8445 ssl default_server;
    server_name _;
    ssl_certificate     /etc/ansible-automation-platform/eda/server.cert;
    ssl_certificate_key /etc/ansible-automation-platform/eda/server.key;
    ssl_ciphers         PROFILE=SYSTEM;
    client_max_body_size 20m;
    root /var/lib/eda/static;
    location /api/eda/ws/ {
        proxy_pass http://eda-ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
    }
    location /api/eda/static/ { alias /var/lib/eda/static/; }
    location / {
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://eda-api;
        proxy_read_timeout 120s;
    }
}
EOF

sudo semanage port -a -t http_port_t -p tcp 8445    # nginx may only bind labeled ports (Lab 18)
sudo firewall-cmd --permanent --add-port=8445/tcp && sudo firewall-cmd --reload
sudo nginx -t && sudo systemctl reload nginx
curl -sk https://127.0.0.1:8445/api/eda/v1/status/ -o /dev/null -w "eda via nginx: %{http_code}\n"  # want: 200
```

## Register behind the gateway

Same REST-with-PKs pattern as [Lab 16](16-service-registration.md) (reuse its `register.py`
helpers). One EDA cluster/node/service, then the service secret:

```python
st  = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}
hp  = find("/http_ports/", "API Port")
eda = ensure("/service_clusters/", "eda", {"name": "eda", "service_type": st["eda"]})
ensure("/service_nodes/", "Node eda - ace-control",
       {"name": "Node eda - ace-control", "address": "192.168.56.10", "service_cluster": eda, "tags": "api"})
ensure("/services/", "eda api",
       {"name": "eda api", "api_slug": "eda", "http_port": hp, "service_cluster": eda,
        "is_service_https": True, "service_path": "/api/eda/", "service_port": 8445,
        "order": 3, "node_tags": "api"})
```

```bash
sudo -u gateway aap-gateway-manage generate_service_secret eda   # RECORD it

sudo tee -a /etc/eda/settings.yaml >/dev/null <<'EOF'
RESOURCE_SERVER:
  URL: https://192.168.56.10
  SECRET_KEY: PASTE-THE-EDA-SECRET
  VALIDATE_HTTPS: false
EOF
sudo vim /etc/eda/settings.yaml    # paste the real secret
sudo systemctl restart automation-eda-api automation-eda-default-worker
```

## Verify — EDA through the platform door

```bash
curl -sk https://192.168.56.10/api/eda/v1/status/ -o /dev/null -w "status: %{http_code}\n"  # 200

curl -sk -u "admin:CHANGE-ME" https://192.168.56.10/api/eda/v1/users/me/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["username"], d["is_superuser"], d["resource"]["resource_type"])'
# want: admin True shared.user — the gateway minted a JWT, EDA's DAB JWT consumer validated
#       it, and resolved the platform's shared user. SSO across controller + hub + EDA.
```

That `shared.user` resource type is the whole platform speaking one identity: the same admin,
proven by the gateway, accepted by the controller, the hub, and EDA alike — each built by hand
from source.

## The payoff — the console is complete

Refresh the platform UI at **`https://192.168.56.10`** one last time. **Automation Decisions**
joins Automation Execution and Automation Content, and the navigation you saw in Lab 7 with a
single entry is now the full platform — one login reaching three services you built from source,
on three different Python versions, sharing one identity.

Again: no UI rebuild. Three registry entries, three envoy routes, one console.

Back to the [README](../README.md) — you built an automation platform, every service and its
console, by hand.
