# Lab 7 — Automation hub

## What this is

Automation hub is the platform's private content repository: the place your automation gets its
collections and execution-environment images from, instead of reaching out to the public internet
every time a job runs.

It is **galaxy_ng** — a set of Ansible-specific plugins — running on **pulpcore**, a general content
management engine. Pulp does the heavy lifting (storage, versioning, syncing, signing); galaxy_ng
adds the Ansible concepts on top.

## Where it fits

The controller pulls collections from here when it builds a project's environment, and pulls EE
images from here when it runs a job. Without a hub, both of those come from `galaxy.ansible.com`
and `quay.io` — which works, until you need an air-gapped network, a curated set of collections, or
a guarantee that yesterday's job and today's job used the same content.

```
   console ──► envoy :443 ──► /api/galaxy/ ──► ace-hub :443 nginx ──┬── pulpcore-api      (REST)
                                                                    ├── pulpcore-content  (downloads)
                                                                    └── pulpcore-worker   (syncs, imports)
```

Like every other component, it joins the platform by inserting rows into the gateway's registry —
and this lab ends with it appearing in the console.

## What you will have at the end

Automation Hub — **galaxy_ng** on **pulpcore** — built from source, running as a
pulp service family (API + content + workers), fronted by its own nginx, and
registered behind the gateway so `https://192.168.56.11/api/galaxy/…`
authenticates with the same platform login as the controller.

```
envoy :443 ──/api/galaxy/…──► nginx :443 ──┬── unix:/…/pulpcore-api.sock      (gunicorn, the REST API + galaxy_ng)
   (gateway JWT)                              └── unix:/…/pulpcore-content.sock  (gunicorn, artifact serving)
                                              pulpcore-worker@1, @2              (tasking)
```

> **Here be dragons — a version-alignment tale.** Hub is the hardest source build in this
> tutorial, and not because of native code — because of **django-ansible-base (DAB)**, the
> shared library that carries the gateway's JWT/RBAC contract. The hub's JWT consumer and the
> gateway's JWT issuer must speak the *same DAB generation*, or single sign-on fails. Read
> the version notes below before you `pip install` anything; getting them wrong costs a
> full rebuild.

All commands on **ace-hub** unless stated otherwise.

## Foundation: user, dirs, database

```bash
sudo useradd --system --home-dir /var/lib/pulp --create-home --shell /bin/bash pulp
sudo install -d -o pulp -g pulp /var/lib/pulp /var/lib/pulp/assets /var/lib/pulp/media /var/lib/pulp/tmp /etc/pulp
sudo usermod -aG redis pulp     # Lab 5 redis socket (hub uses db 2)

sudo -iu postgres psql -c "CREATE USER pulp WITH PASSWORD 'CHANGE-ME';"
sudo -iu postgres psql -c "CREATE DATABASE pulp OWNER pulp;"
```

Pulp stores encrypted fields, so it needs the postgres **`hstore`** extension — which lives
in `postgresql-contrib` and must be created *in the pulp database* by a superuser:

```bash
sudo dnf -y install postgresql-contrib
sudo -iu postgres psql -d pulp -c "CREATE EXTENSION IF NOT EXISTS hstore;"
```

## Python 3.11, not 3.12

The galaxy_ng/pulpcore stack of this era pins `setuptools<66`, and that setuptools calls
`pkgutil.ImpImporter`, which **Python 3.12 removed**. So the hub venv is built on **Python
3.11**, even though the controller used 3.12.

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
> **django-ansible-base (`2025.11.dev`)** — close enough to the gateway's DAB generation to
> share the JWT format. If SSO later returns a JWT-claim error, the very first thing to check is
> whether the hub's DAB and the gateway's DAB are the same generation (`pip show
> django-ansible-base` in both venvs).
>
> **Don't panic at a version mismatch, though.** On the amd64 run galaxy_ng `main` pinned DAB
> `2025.11.24` while the gateway/controller/EDA venvs had already moved to `2026.7.23` — a
> whole generation newer — and **SSO still worked**. A one-generation lag is tolerated; the
> `Token is missing the "objects" claim` hard failure comes from the *much* older DAB the
> `stable-4.x` branches pin, which is why `main` (above), not a stable tag, is the load-bearing
> choice.

## Settings — `/etc/pulp/settings.py`

pulpcore reads `PULP_SETTINGS`. Write the override by hand — pulpcore's defaults plus the
galaxy_ng gateway settings, adapted to our local postgres + unix-socket redis:

First the pulp **database-fields encryption key** — a Fernet key (url-safe base64 of 32
random bytes) that pulp uses to encrypt secret model fields; without it, `migrate` refuses
to start:

```bash
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

CONTENT_ORIGIN = "https://192.168.56.11"
ANSIBLE_API_HOSTNAME = "https://192.168.56.11"
ANSIBLE_CONTENT_HOSTNAME = "https://192.168.56.11/pulp/content"
TOKEN_SERVER = "https://192.168.56.11/token/"
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
ANSIBLE_BASE_JWT_KEY = "https://192.168.56.11"
ANSIBLE_BASE_ROLES_REQUIRE_VIEW = False
CSRF_TRUSTED_ORIGINS = ["https://192.168.56.11"]
ENABLE_SERVICE_BACKED_SSO = False
GALAXY_AUTHENTICATION_CLASSES = [
    "galaxy_ng.app.auth.session.SessionAuthentication",
    "ansible_base.jwt_consumer.hub.auth.HubJWTAuth",
    "rest_framework.authentication.TokenAuthentication",
    "rest_framework.authentication.BasicAuthentication",
]
EOF
sudo chown pulp:pulp /etc/pulp/settings.py
sudo chmod 0640 /etc/pulp/settings.py
sudo vim /etc/pulp/settings.py    # set the real DB password + a random SECRET_KEY
```

The PATH wrapper — `pulpcore-manager`, with `PULP_SETTINGS`, the Django settings
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

sudo semanage fcontext -a -t bin_t '/var/lib/pulp/venv/bin(/.*)?'   # Lab 11's 203/EXEC fix
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

## nginx

Hub has a host to itself, so it serves **443** like the controller and EDA do. Only the gateway
uses a non-standard port, and only because envoy shares its machine.

The certificate comes from [Lab 3](03-internal-ca.md)'s two-step procedure — the key is generated
here and never leaves:

```bash
# on ace-hub
sudo /usr/local/sbin/ace-request-cert pulp_webserver /etc/pulp/certs pulp
```
```bash
# on ace-gateway
sudo /usr/local/sbin/ace-sign-request ace-hub-pulp_webserver
```
```bash
# back on ace-hub
sudo install -o root -g pulp -m 0644 /vagrant/ace-hub-pulp_webserver.crt /etc/pulp/certs/pulp_webserver.crt
sudo rm -f /vagrant/ace-hub-pulp_webserver.crt
sudo openssl verify /etc/pulp/certs/pulp_webserver.crt      # want: OK

sudo tee /etc/nginx/conf.d/automation-hub.nginx.conf >/dev/null <<'EOF'
upstream pulp-api     { server unix:/run/pulpcore-api/pulpcore-api.sock; }
upstream pulp-content { server unix:/run/pulpcore-content/pulpcore-content.sock; }

server {
    listen 443 ssl default_server;
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

> No `semanage port` step is needed: 443 is already labelled `http_port_t`. That is one of the
> quieter benefits of every component having its own host — a non-standard port would need
> labelling, and the failure when you forget is silent (`nginx -t` passes, the reload succeeds,
> nothing binds, and the only evidence is `bind() … (13: Permission denied)` in the *main* error
> log).

```bash
sudo firewall-cmd --permanent --add-port=443/tcp && sudo firewall-cmd --reload
sudo nginx -t && sudo systemctl reload nginx
curl -sk https://127.0.0.1:443/api/galaxy/pulp/api/v3/status/ -o /dev/null -w "hub via nginx: %{http_code}\n"  # want: 200
```

## Register the hub behind the gateway

Same REST-with-PKs pattern as [Lab 6](06-controller.md) — a `hub` cluster and node,
a `galaxy` service under `/api/galaxy/`, plus the container-registry routes. Save as
`reghub.py` (reuse the `call/find/ensure` helpers from Lab 16's `register.py`):

```python
st  = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}
hp  = find("/http_ports/", "API Port")
hub = ensure("/service_clusters/", "hub", {"name": "hub", "service_type": st["hub"]})
ensure("/service_nodes/", "Node hub - ace-hub",
       {"name": "Node hub - ace-hub", "address": "192.168.56.10", "service_cluster": hub})
ensure("/services/", "galaxy api",
       {"name": "galaxy api", "api_slug": "galaxy", "http_port": hp, "service_cluster": hub,
        "is_service_https": True, "service_path": "/api/galaxy/", "service_port": 443, "order": 2})
for nm, gp in [("hub container registry", "/v2/"), ("pulp content", "/pulp/"),
               ("hub ui static", "/static/galaxy_ng/"), ("pulp container tokens", "/token/")]:
    if find("/routes/", nm):
        continue
    call("POST", "/routes/", {"name": nm, "gateway_path": gp, "service_path": gp, "http_port": hp,
        "service_cluster": hub, "is_service_https": True, "service_port": 443, "enable_gateway_auth": True})
```

Then mint the hub's service secret and add it to the pulp settings so galaxy_ng trusts the
gateway back (the api-slug is **`galaxy`**, not `hub`):

```bash
sudo -u gateway aap-gateway-manage generate_service_secret galaxy   # RECORD it

sudo tee -a /etc/pulp/settings.py >/dev/null <<'EOF'
RESOURCE_SERVER = {
    "URL": "https://192.168.56.11",
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
curl -sk https://192.168.56.11/api/galaxy/pulp/api/v3/status/ | python3 -m json.tool | grep component

# the real test: JWT SSO. one platform login reaches galaxy_ng as the platform admin:
curl -skL -u "admin:CHANGE-ME" https://192.168.56.11/api/galaxy/_ui/v1/me/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["username"], d["is_superuser"])'
# want: admin True — the gateway minted a JWT, galaxy_ng's HubJWTAuth validated it,
#       and mapped it to the platform admin. SSO across the whole platform.
```

> If `me/` returns `401 Token is missing the "objects" claim`, the hub's DAB is older than the
> gateway's — you installed a stable galaxy_ng branch instead of `main`. Rebuild the venv from
> `main` (top of this lab). A `503 no healthy upstream` right after a restart is just envoy's
> health check catching up — retry in a few seconds.

## The payoff — it appears in the console

Now open the platform UI from [Lab 5](05-gateway.md) at **`https://192.168.56.11`** and
**refresh**. The navigation has grown a section: **Automation Content**, alongside Automation
Execution.

Nothing about the UI changed — no rebuild, no redeploy, not even a restart. You added rows to the
gateway's service registry, envoy picked up the new route within five seconds, and the console
asked `GET /api/` and drew what it found. That is the service registry doing exactly what
[Lab 6](06-controller.md) built it for.

Next: [Event-Driven Ansible](08-eda.md)
