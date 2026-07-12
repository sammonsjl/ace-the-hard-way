# Lab 17 — Automation Hub (galaxy_ng from source)

## What you will have at the end

Automation Hub — **galaxy_ng** on **pulpcore** — built from source, running as a
pulp service family (API + content + workers), fronted by its own nginx, and
registered behind the gateway so `https://192.168.56.10:8443/api/galaxy/…`
authenticates with the same platform login as the controller.

```
envoy :8443 ──/api/galaxy/…──► nginx :8444 ──┬── unix:/…/pulpcore-api.sock      (gunicorn, the REST API + galaxy_ng)
   (gateway JWT)                              └── unix:/…/pulpcore-content.sock  (gunicorn, artifact serving)
                                              pulpcore-worker@1, @2              (tasking)
```

> **Here be dragons — a version-alignment tale.** Hub is the hardest source build in this
> tutorial, and not because of native code — because of **django-ansible-base (DAB)**, the
> shared library that carries the gateway's JWT/RBAC contract. The hub's JWT consumer and the
> gateway's JWT issuer must speak the *same DAB generation*, or single sign-on fails. Read
> the version notes below before you `pip install` anything; getting them wrong costs a
> full rebuild.

All commands on **ace-control** (hub is a control-plane service in this single-box lab).

## Foundation: user, dirs, database

```bash
sudo useradd --system --home-dir /var/lib/pulp --create-home --shell /bin/bash pulp
sudo install -d -o pulp -g pulp /var/lib/pulp /var/lib/pulp/assets /var/lib/pulp/media /var/lib/pulp/tmp /etc/pulp
sudo usermod -aG redis pulp     # Lab 4 redis socket (hub uses db 2)

sudo -u postgres psql -c "CREATE USER pulp WITH PASSWORD 'CHANGE-ME';"
sudo -u postgres psql -c "CREATE DATABASE pulp OWNER pulp;"
```

Pulp stores encrypted fields, so it needs the postgres **`hstore`** extension — which lives
in `postgresql-contrib` and must be created *in the pulp database* by a superuser:

```bash
sudo dnf -y install postgresql-contrib
sudo -u postgres psql -d pulp -c "CREATE EXTENSION IF NOT EXISTS hstore;"
```

## Python 3.11, not 3.12

The galaxy_ng/pulpcore stack of this era pins `setuptools<66`, and that setuptools calls
`pkgutil.ImpImporter`, which **Python 3.12 removed**. So the hub venv is built on **Python
3.11** — the same interpreter AAP 2.6 ships for pulp — even though the controller used 3.12.

```bash
sudo dnf -y install python3.11 python3.11-devel
```

## Install galaxy_ng from git `main` (this version choice is load-bearing)

**Do not `pip install galaxy-ng` from PyPI.** PyPI tops out at 4.9.2, which predates the
gateway integration entirely (no `django-ansible-base`, no JWT consumer). And the *stable*
branches (e.g. `stable-4.10`) pin an **older DAB** than the gateway's jewel-devel — their
migrations run, but SSO later fails with `Token is missing the "objects" claim`, and bumping
DAB alone breaks galaxy_ng's own migrations. The branch that lines up with jewel-devel's DAB
is **`main`**:

```bash
sudo install -d -o pulp -g pulp /opt/galaxy_ng
sudo -u pulp python3.11 -m venv /var/lib/pulp/venv
sudo -u pulp bash <<'EOF'
set -euo pipefail
source /var/lib/pulp/venv/bin/activate
pip install --upgrade pip "setuptools<66" wheel
pip install "galaxy_ng @ git+https://github.com/ansible/galaxy_ng.git@main" gunicorn
pip list | grep -iE 'galaxy-ng|pulpcore|django-ansible-base'  # RECORD these — moving tips
EOF
```

> This pulls galaxy_ng (`4.12.0.dev`), pulpcore (`3.105.x`), pulp-ansible, pulp-container, and
> **django-ansible-base (`2025.11.dev`)** — the same DAB generation the gateway (Lab 15) built
> against. If SSO later returns a JWT-claim error, the very first thing to check is whether the
> hub's DAB and the gateway's DAB are the same generation (`pip show django-ansible-base` in
> both venvs).

## Settings — `/etc/pulp/settings.py`

pulpcore reads `PULP_SETTINGS`. Write the override the bundle's `_pulp_settings_defaults` +
galaxy_ng gateway block produce, adapted to our local postgres + unix-socket redis:

```bash
sudo -u pulp bash -c 'openssl rand -base64 32 | tr "+/" "-_" > /etc/pulp/certs-fernet.key'  # temp, see below
sudo install -d -o pulp -g pulp -m 0750 /etc/pulp/certs
sudo -u pulp bash -c 'openssl rand -base64 32 | tr "+/" "-_" > /etc/pulp/certs/database_fields.symmetric.key'
sudo chmod 0640 /etc/pulp/certs/database_fields.symmetric.key

sudo tee /etc/pulp/settings.py >/dev/null <<'EOF'
DATABASES = {
    "default": {
        "ENGINE": "django.db.backends.postgresql",
        "NAME": "pulp", "USER": "pulp", "PASSWORD": "CHANGE-ME",
        "HOST": "localhost", "PORT": 5432,
    }
}
REDIS_URL = "unix:///var/run/redis/redis.sock?db=2"
SECRET_KEY = "CHANGE-ME-RANDOM"
DB_ENCRYPTION_KEY = "/etc/pulp/certs/database_fields.symmetric.key"

CONTENT_ORIGIN = "https://192.168.56.10:8443"
ANSIBLE_API_HOSTNAME = "https://192.168.56.10:8443"
ANSIBLE_CONTENT_HOSTNAME = "https://192.168.56.10:8443/pulp/content"
TOKEN_SERVER = "https://192.168.56.10:8443/token/"
API_ROOT = "/api/galaxy/pulp/"
CONTENT_PATH_PREFIX = "/pulp/content/"
STATIC_ROOT = "/var/lib/pulp/assets"
MEDIA_ROOT = "/var/lib/pulp/media"
WORKING_DIRECTORY = "/var/lib/pulp/tmp"
GALAXY_API_DEFAULT_DISTRIBUTION_BASE_PATH = "published"
ALLOWED_CONTENT_CHECKSUMS = ["sha224", "sha256", "sha384", "sha512"]
GALAXY_REQUIRE_CONTENT_APPROVAL = False
TOKEN_AUTH_DISABLED = True

# local filesystem storage — newer pulpcore refuses to start otherwise
REDIRECT_TO_OBJECT_STORAGE = False
STORAGES = {
    "default": {
        "BACKEND": "pulpcore.app.models.storage.FileSystem",
        "OPTIONS": {"location": "/var/lib/pulp/media", "base_url": "/pulp/content"},
    },
    "staticfiles": {"BACKEND": "django.contrib.staticfiles.storage.StaticFilesStorage"},
}

# gateway integration (galaxy_ng JWT consumer)
ANSIBLE_BASE_JWT_REDIRECT_TYPE = "hub"
ANSIBLE_BASE_JWT_VALIDATE_CERT = False
ANSIBLE_BASE_JWT_KEY = "https://192.168.56.10:8443"
ANSIBLE_BASE_ROLES_REQUIRE_VIEW = False
CSRF_TRUSTED_ORIGINS = ["https://192.168.56.10:8443"]
ENABLE_SERVICE_BACKED_SSO = False
GALAXY_AUTHENTICATION_CLASSES = [
    "galaxy_ng.app.auth.session.SessionAuthentication",
    "ansible_base.jwt_consumer.hub.auth.HubJWTAuth",
    "rest_framework.authentication.TokenAuthentication",
    "rest_framework.authentication.BasicAuthentication",
]
EOF
sudo rm -f /etc/pulp/certs-fernet.key
sudo chown pulp:pulp /etc/pulp/settings.py
sudo chmod 0640 /etc/pulp/settings.py
sudo vim /etc/pulp/settings.py    # set the real DB password + a random SECRET_KEY
```

The RPM-style manage wrapper — `pulpcore-manager`, with `PULP_SETTINGS`, the Django settings
module, and `OPENSSL_armcap=0` (pulp imports `cryptography`; same Apple-Silicon SIGILL as the
gateway):

```bash
sudo tee /usr/bin/pulpcore-manager >/dev/null <<'EOF'
#!/bin/bash
export OPENSSL_armcap=0
export PULP_SETTINGS=/etc/pulp/settings.py
export DJANGO_SETTINGS_MODULE=pulpcore.app.settings
exec /var/lib/pulp/venv/bin/pulpcore-manager "$@"
EOF
sudo chmod 0755 /usr/bin/pulpcore-manager
```

## Migrate, admin, static

```bash
sudo -u pulp pulpcore-manager migrate                       # want: long OK run, RoleDefinitions created
sudo -u pulp pulpcore-manager reset-admin-password --password CHANGE-ME
sudo bash -c 'umask 022 && OPENSSL_armcap=0 PULP_SETTINGS=/etc/pulp/settings.py \
  DJANGO_SETTINGS_MODULE=pulpcore.app.settings \
  /var/lib/pulp/venv/bin/pulpcore-manager collectstatic --noinput --clear'
```

## The pulp service family (systemd)

Sockets on tmpfs, one environment file, three unit types (`api`, `content`, templated
`worker@`):

```bash
sudo tee /etc/tmpfiles.d/pulp.conf >/dev/null <<'EOF'
d /run/pulpcore-api 0755 pulp pulp -
d /run/pulpcore-content 0755 pulp pulp -
d /run/pulpcore-worker-1 0755 pulp pulp -
d /run/pulpcore-worker-2 0755 pulp pulp -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/pulp.conf

sudo tee /etc/default/pulpcore >/dev/null <<'EOF'
PULP_SETTINGS=/etc/pulp/settings.py
DJANGO_SETTINGS_MODULE=pulpcore.app.settings
OPENSSL_armcap=0
EOF

sudo tee /etc/systemd/system/pulpcore-api.service >/dev/null <<'EOF'
[Unit]
Description=Pulp API Server
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
Type=notify
EnvironmentFile=/etc/default/pulpcore
User=pulp
Group=pulp
RuntimeDirectory=pulpcore-api
ExecStart=/var/lib/pulp/venv/bin/pulpcore-api --name pulp-api --bind unix:/run/pulpcore-api/pulpcore-api.sock --workers 2 --timeout 90 --access-logfile -
Restart=always
RestartSec=3
LimitNOFILE=524288
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/pulpcore-content.service >/dev/null <<'EOF'
[Unit]
Description=Pulp Content App
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
Type=notify
EnvironmentFile=/etc/default/pulpcore
User=pulp
Group=pulp
WorkingDirectory=/run/pulpcore-content/
RuntimeDirectory=pulpcore-content
ExecStart=/var/lib/pulp/venv/bin/pulpcore-content --name pulp-content --bind unix:/run/pulpcore-content/pulpcore-content.sock --workers 2 --timeout 90 --access-logfile -
Restart=always
RestartSec=3
LimitNOFILE=524288
[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/pulpcore-worker@.service >/dev/null <<'EOF'
[Unit]
Description=Pulp Worker %i
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/pulpcore
User=pulp
Group=pulp
WorkingDirectory=/run/pulpcore-worker-%i/
RuntimeDirectory=pulpcore-worker-%i
ExecStart=/var/lib/pulp/venv/bin/pulpcore-worker
Restart=always
RestartSec=3
LimitNOFILE=524288
[Install]
WantedBy=multi-user.target
EOF

sudo semanage fcontext -a -t bin_t '/var/lib/pulp/venv/bin(/.*)?'   # Lab 8's 203/EXEC fix
sudo restorecon -Rv /var/lib/pulp/venv/bin
sudo systemctl daemon-reload
sudo systemctl enable --now pulpcore-api pulpcore-content pulpcore-worker@1 pulpcore-worker@2
```

Verify the backend before putting nginx in front:

```bash
curl -s --unix-socket /run/pulpcore-api/pulpcore-api.sock \
  http://localhost/api/galaxy/pulp/api/v3/status/ | python3 -m json.tool | grep -E 'component|online'
# want: components core/galaxy/container/ansible/…, online_workers and online_content_apps > 0
```

## nginx front on 8444 (443 belongs to the controller)

Hub gets its own server block and its own lab-CA-signed cert, on **8444** — the controller's
nginx already owns 443 on this shared box.

```bash
sudo install -d -o pulp -g pulp -m 0750 /etc/pulp/certs
sudo openssl genrsa -out /etc/pulp/certs/pulp_webserver.key 2048
sudo openssl req -new -key /etc/pulp/certs/pulp_webserver.key -subj "/CN=ace-control" -out /tmp/hub.csr
printf "subjectAltName=DNS:ace-control,DNS:localhost,IP:192.168.56.10,IP:127.0.0.1\n" | sudo tee /tmp/hub_ext.cnf >/dev/null
sudo openssl x509 -req -in /tmp/hub.csr -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key \
  -CAcreateserial -days 825 -sha256 -out /etc/pulp/certs/pulp_webserver.crt -extfile /tmp/hub_ext.cnf
sudo chown pulp:pulp /etc/pulp/certs/pulp_webserver.crt /etc/pulp/certs/pulp_webserver.key
sudo chmod 0640 /etc/pulp/certs/pulp_webserver.key
sudo rm -f /tmp/hub.csr /tmp/hub_ext.cnf

sudo tee /etc/nginx/conf.d/automation-hub.nginx.conf >/dev/null <<'EOF'
upstream pulp-api     { server unix:/run/pulpcore-api/pulpcore-api.sock; }
upstream pulp-content { server unix:/run/pulpcore-content/pulpcore-content.sock; }

server {
    listen 8444 ssl default_server;
    server_name _;
    ssl_certificate     /etc/pulp/certs/pulp_webserver.crt;
    ssl_certificate_key /etc/pulp/certs/pulp_webserver.key;
    ssl_ciphers         PROFILE=SYSTEM;
    client_max_body_size 20m;
    root /var/lib/pulp/assets;

    location /pulp/content/ {
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
        proxy_pass http://pulp-content;
    }
    location /static/ { alias /var/lib/pulp/assets/; }
    location / {
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_redirect off;
        proxy_pass http://pulp-api;
        proxy_read_timeout 120s;
    }
}
EOF
```

> **SELinux port trap.** nginx (`httpd_t`) may only bind ports labeled `http_port_t`, and 8444
> isn't one of them by default — `nginx -t` passes but the reload fails with
> `bind() to 0.0.0.0:8444 failed (13: Permission denied)`. Label the port first:
> ```bash
> sudo semanage port -a -t http_port_t -p tcp 8444
> ```

```bash
sudo firewall-cmd --permanent --add-port=8444/tcp && sudo firewall-cmd --reload
sudo nginx -t && sudo systemctl reload nginx
curl -sk https://127.0.0.1:8444/api/galaxy/pulp/api/v3/status/ -o /dev/null -w "hub via nginx: %{http_code}\n"  # want: 200
```

## Register the hub behind the gateway

Same REST-with-PKs pattern as [Lab 16](16-service-registration.md) — a `hub` cluster and node,
a `galaxy` service under `/api/galaxy/`, plus the container-registry routes. Save as
`reghub.py` (reuse the `call/find/ensure` helpers from Lab 16's `register.py`):

```python
st  = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}
hp  = find("/http_ports/", "API Port")
hub = ensure("/service_clusters/", "hub", {"name": "hub", "service_type": st["hub"]})
ensure("/service_nodes/", "Node hub - ace-control",
       {"name": "Node hub - ace-control", "address": "192.168.56.10", "service_cluster": hub})
ensure("/services/", "galaxy api",
       {"name": "galaxy api", "api_slug": "galaxy", "http_port": hp, "service_cluster": hub,
        "is_service_https": True, "service_path": "/api/galaxy/", "service_port": 8444, "order": 2})
for nm, gp in [("hub container registry", "/v2/"), ("pulp content", "/pulp/"),
               ("hub ui static", "/static/galaxy_ng/"), ("pulp container tokens", "/token/")]:
    if find("/routes/", nm):
        continue
    call("POST", "/routes/", {"name": nm, "gateway_path": gp, "service_path": gp, "http_port": hp,
        "service_cluster": hub, "is_service_https": True, "service_port": 8444, "enable_gateway_auth": True})
```

Then mint the hub's service secret and add it to the pulp settings so galaxy_ng trusts the
gateway back (the api-slug is **`galaxy`**, not `hub`):

```bash
sudo -u gateway aap-gateway-manage generate_service_secret galaxy   # RECORD it

sudo tee -a /etc/pulp/settings.py >/dev/null <<'EOF'
RESOURCE_SERVER = {
    "URL": "https://192.168.56.10:8443",
    "SECRET_KEY": "PASTE-THE-GALAXY-SECRET",
    "VALIDATE_HTTPS": False,
}
EOF
sudo vim /etc/pulp/settings.py    # paste the real secret
sudo systemctl restart pulpcore-api pulpcore-content pulpcore-worker@1 pulpcore-worker@2
```

## Verify — hub through the platform door

```bash
# unauthenticated status, proxied through envoy → nginx → pulp
curl -sk https://192.168.56.10:8443/api/galaxy/pulp/api/v3/status/ | python3 -m json.tool | grep component

# the real test: JWT SSO. one platform login reaches galaxy_ng as the platform admin:
curl -skL -u "admin:CHANGE-ME" https://192.168.56.10:8443/api/galaxy/_ui/v1/me/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["username"], d["is_superuser"])'
# want: admin True — the gateway minted a JWT, galaxy_ng's HubJWTAuth validated it,
#       and mapped it to the platform admin. SSO across the whole platform.
```

> If `me/` returns `401 Token is missing the "objects" claim`, the hub's DAB is older than the
> gateway's — you installed a stable galaxy_ng branch instead of `main`. Rebuild the venv from
> `main` (top of this lab). A `503 no healthy upstream` right after a restart is just envoy's
> health check catching up — retry in a few seconds.

Next: [Event-Driven Ansible](18-eda.md)
