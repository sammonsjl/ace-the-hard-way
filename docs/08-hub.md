# Lab 8 — Automation hub

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
registered behind the gateway so `https://192.168.1.41/api/galaxy/…`
authenticates with the same platform login as the controller.

```
envoy :443 ──/api/galaxy/…──► nginx :443 ──┬── unix:/…/pulpcore-api.sock      (gunicorn, the REST API + galaxy_ng)
   (gateway JWT)                              └── unix:/…/pulpcore-content.sock  (gunicorn, artifact serving)
                                              pulpcore-worker@1, @2              (tasking)
```

All commands on **ace-hub** unless stated otherwise.

## Foundation: user, dirs, database

```bash
sudo useradd --system --home-dir /var/lib/pulp --create-home --shell /bin/bash pulp
sudo install -d -o pulp -g pulp /var/lib/pulp /var/lib/pulp/assets /var/lib/pulp/media /var/lib/pulp/tmp /etc/pulp
```

The `pulp` role and database already exist — [Lab 4](04-postgresql.md) created all four up front.
Confirm this node can reach it:

```bash
sudo dnf -y install postgresql
PGPASSWORD='CHANGE-ME-pulp' psql -h ace-db -U pulp -d pulp -c 'SELECT 1'
```

Pulp stores encrypted fields, so it needs the postgres **`hstore`** extension. Creating an
extension requires a superuser, and superuser is a thing you have on the database host — so this
one step runs **on ace-db**, not here:

**On `ace-db`:**

```bash
sudo dnf -y install postgresql-contrib
sudo -iu postgres psql -d pulp -c "CREATE EXTENSION IF NOT EXISTS hstore;"
sudo -iu postgres psql -d pulp -c '\dx' | grep hstore
```

## Build toolchain, and Python 3.11 rather than 3.12

The galaxy_ng/pulpcore stack of this era pins `setuptools<66`, and that setuptools calls
`pkgutil.ImpImporter`, which **Python 3.12 removed**. So the hub venv is built on **Python 3.11**,
even though the controller used 3.12. Two components, two interpreters, on two machines — which is
one of the quieter arguments for giving each component its own host.

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.11 python3.11-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel \
  libxml2-devel libxslt-devel
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
pip list | grep -iE 'galaxy-ng|pulpcore|django-ansible-base'
EOF
```

> This pulls galaxy_ng (`4.12.0.dev`), pulpcore (`3.105.x`), pulp-ansible, pulp-container, and
> **django-ansible-base (`2025.11.dev`)** — close enough to the gateway's DAB generation to
> share the JWT format. If SSO later returns a JWT-claim error, the very first thing to check is
> whether the hub's DAB and the gateway's DAB are the same generation (`pip show
> django-ansible-base` in both venvs).

## Settings — `/etc/pulp/settings.py`

pulpcore reads `PULP_SETTINGS`. Write the override by hand — pulpcore's defaults plus the
galaxy_ng gateway settings, adapted to the database on ace-db and redis on ace-gateway:

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
        "HOST": "ace-db", "PORT": 5432,
    }
}
REDIS_URL = "redis://ace-gateway:6379/2"
SECRET_KEY = "CHANGE-ME-RANDOM"
DB_ENCRYPTION_KEY = "/etc/pulp/certs/database_fields.symmetric.key"

CONTENT_ORIGIN = "https://192.168.1.41"
ANSIBLE_API_HOSTNAME = "https://192.168.1.41"
ANSIBLE_CONTENT_HOSTNAME = "https://192.168.1.41/pulp/content"
TOKEN_SERVER = "https://192.168.1.41/token/"
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
ANSIBLE_BASE_JWT_KEY = "https://192.168.1.41"
ANSIBLE_BASE_ROLES_REQUIRE_VIEW = False
CSRF_TRUSTED_ORIGINS = ["https://192.168.1.41"]
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
sudo vim /etc/pulp/settings.py
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
sudo -u pulp pulpcore-manager migrate
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
After=network-online.target pulpcore.service
Wants=network-online.target
PartOf=pulpcore.service
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
After=network-online.target pulpcore.service
Wants=network-online.target
PartOf=pulpcore.service
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
After=network-online.target pulpcore.service
Wants=network-online.target
PartOf=pulpcore.service
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

sudo semanage fcontext -a -t bin_t '/var/lib/pulp/venv/bin(/.*)?'
sudo restorecon -Rv /var/lib/pulp/venv/bin
```

Hub gets the same lifecycle handle the controller has: a unit that runs nothing, with the real
services declaring `PartOf=` it. `systemctl restart pulpcore` bounces the API, the content app and
both workers in order; `systemctl stop pulpcore` stops the lot. A packaged install ships exactly
this, down to the `/bin/true`.

```bash
sudo tee /etc/systemd/system/pulpcore.service >/dev/null <<'EOF'
[Unit]
Description=Pulpcore Application

[Service]
Type=oneshot
ExecStart=/bin/true
RemainAfterExit=yes

[Install]
WantedBy=multi-user.target
EOF
```

```bash
sudo systemctl daemon-reload
sudo systemctl enable pulpcore >/dev/null
sudo systemctl enable --now pulpcore-api pulpcore-content pulpcore-worker@1 pulpcore-worker@2
```

Verify the backend before putting nginx in front:

```bash
curl -s --unix-socket /run/pulpcore-api/pulpcore-api.sock \
  http://localhost/api/galaxy/pulp/api/v3/status/ | python3 -m json.tool | grep -E 'component|online'
```

## nginx

Hub has a host to itself, so it serves **443** like the controller and EDA do. Only the gateway
uses a non-standard port, and only because envoy shares its machine.

The certificate comes from [Lab 3](03-internal-ca.md)'s two-step procedure — the key is generated
here and never leaves:

**On `ace-hub`:**

```bash
sudo /usr/local/sbin/ace-request-cert pulp_webserver /etc/pulp/certs pulp
```

**On `ace-gateway`:**

```bash
sudo /usr/local/sbin/ace-sign-request ace-hub-pulp_webserver
```

**Back on `ace-hub`:**

```bash
sudo install -o root -g pulp -m 0644 /srv/ace/ace-hub-pulp_webserver.crt /etc/pulp/certs/pulp_webserver.crt
sudo rm -f /srv/ace/ace-hub-pulp_webserver.crt
sudo openssl verify /etc/pulp/certs/pulp_webserver.crt

sudo dnf -y module enable nginx:1.24
sudo dnf -y install nginx
sudo setsebool -P httpd_can_network_connect on

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
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=443/tcp && sudo firewall-cmd --reload
```

> **firewalld is not on this box yet.** The Rocky GenericCloud image does not ship it, and only
> [Lab 6](06-controller.md) has installed it so far — on the controller. Skip the install line and
> the next command is `sudo: firewall-cmd: command not found`, which reads like a broken lab rather
> than a missing package.

nginx reaches both pulpcore sockets over unix, which crosses the same pair of SELinux checks
[Lab 6](06-controller.md) hit — `write` on the socket inode and `connectto` against the domain
that bound it. Same two-rule module, same reason:

```bash
sudo dnf -y install setools-console
sudo tee /tmp/ace-nginx-upstream.te >/dev/null <<'EOF'
module ace-nginx-upstream 1.1;

require {
    type httpd_t;
    type unconfined_service_t;
    type var_run_t;
    class unix_stream_socket connectto;
    class sock_file write;
}

allow httpd_t var_run_t:sock_file write;
allow httpd_t unconfined_service_t:unix_stream_socket connectto;
EOF
checkmodule -M -m -o /tmp/ace-nginx-upstream.mod /tmp/ace-nginx-upstream.te
semodule_package -o /tmp/ace-nginx-upstream.pp -m /tmp/ace-nginx-upstream.mod
sudo semodule -i /tmp/ace-nginx-upstream.pp

sudo nginx -t && sudo systemctl enable --now nginx
curl -sk https://127.0.0.1:443/api/galaxy/pulp/api/v3/status/ -o /dev/null -w "hub via nginx: %{http_code}\n"
```

> Skip the module and you get a **502** with `connect() to unix:/run/pulpcore-api/pulpcore-api.sock
> failed (13: Permission denied)` in the error log — while `ausearch` reports *nothing*, because the
> `sock_file` denial sits behind a `dontaudit` rule.

## Register the hub behind the gateway

Same registry rows as [Lab 5](05-gateway.md) and [Lab 6](06-controller.md) — a `hub` cluster and
node, a `galaxy` service under `/api/galaxy/`, plus the container-registry routes. Those two labs
did it with `curl`, which was fine for four calls. The hub needs nine, every one of them
referencing another row by primary key, so from here on it is worth a small helper.

Save this as `register.py` on **ace-gateway** — Lab 9 reuses it as-is:

```python
#!/usr/bin/env python3
"""Helpers for registering a service with the gateway's REST API.

Everything the gateway routes is a row in its registry, and each row references
others by primary key. Nothing here hard-codes a PK: look them up by name.
Idempotent — re-running creates nothing twice.
"""
import base64, getpass, json, os, ssl, urllib.error, urllib.request

GW = "https://127.0.0.1:8443/api/gateway/v1"
PW = os.environ.get("GW_PW") or getpass.getpass("gateway admin password: ")

# 127.0.0.1 is not in the certificate's SAN — the name is. Verification is off for
# this loopback call only; every cross-host call in these labs verifies properly.
CTX = ssl.create_default_context()
CTX.check_hostname = False
CTX.verify_mode = ssl.CERT_NONE

AUTH = "Basic " + base64.b64encode(f"admin:{PW}".encode()).decode()


def call(method, path, body=None):
    req = urllib.request.Request(
        GW + path, method=method,
        data=json.dumps(body).encode() if body is not None else None)
    req.add_header("Content-Type", "application/json")
    req.add_header("Authorization", AUTH)
    try:
        with urllib.request.urlopen(req, context=CTX) as r:
            raw = r.read()
            return json.loads(raw) if raw else {}
    except urllib.error.HTTPError as e:
        raise SystemExit(f"{method} {path} -> {e.code}: {e.read().decode()[:300]}")


def find(path, name):
    """Return the id of the row with this name, or None."""
    for row in call("GET", path)["results"]:
        if row.get("name") == name:
            return row["id"]
    return None


def ensure(path, name, body):
    """Create the row if it isn't there; return its id either way."""
    existing = find(path, name)
    if existing is not None:
        print(f"  = {name} (id {existing})")
        return existing
    new = call("POST", path, body)["id"]
    print(f"  + {name} (id {new})")
    return new
```

Then append the hub's own rows to the bottom of that same file and run it with
`python3 register.py`:

```python
st  = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}
hp  = find("/http_ports/", "API Port")
hub = ensure("/service_clusters/", "hub", {"name": "hub", "service_type": st["hub"]})
ensure("/service_nodes/", "Node hub - ace-hub",
       {"name": "Node hub - ace-hub", "address": "192.168.1.43", "service_cluster": hub})
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
sudo -u gateway aap-gateway-manage generate_service_secret galaxy

sudo tee -a /etc/pulp/settings.py >/dev/null <<'EOF'
RESOURCE_SERVER = {
    "URL": "https://192.168.1.41",
    "SECRET_KEY": "PASTE-THE-GALAXY-SECRET",
    "VALIDATE_HTTPS": False,
}
EOF
sudo vim /etc/pulp/settings.py
sudo systemctl restart pulpcore-api pulpcore-content pulpcore-worker@1 pulpcore-worker@2
```

## Verify — hub through the platform door

```bash
curl -sk https://192.168.1.41/api/galaxy/pulp/api/v3/status/ | python3 -m json.tool | grep component

curl -skL -u "admin:CHANGE-ME" https://192.168.1.41/api/galaxy/_ui/v1/me/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["username"], d["is_superuser"])'
```

> If `me/` returns `401 Token is missing the "objects" claim`, the hub's DAB is older than the
> gateway's — you installed a stable galaxy_ng branch instead of `main`. Rebuild the venv from
> `main` (top of this lab).
>
> A `503 no healthy upstream` right after the restart is just envoy's health check catching up —
> but budget **a couple of minutes**, not a few seconds. On the reference run it answered `503`
> steadily for about two minutes before flipping. Watch it rather than guessing:
> ```bash
> curl -s "http://127.0.0.1:19000/stats?filter=cluster-.*-443-nodes_api" | grep membership_healthy
> ```

## The payoff — it appears in the console

Now open the platform UI from [Lab 5](05-gateway.md) at **`https://192.168.1.41`** and
**refresh**. The navigation has grown a section: **Automation Content**, alongside Automation
Execution.

Nothing about the UI changed — no rebuild, no redeploy, not even a restart. You added rows to the
gateway's service registry, envoy picked up the new route within five seconds, and the console
asked `GET /api/` and drew what it found. That is the service registry doing exactly what
[Lab 6](06-controller.md) built it for.

Next: [Event-Driven Ansible](09-eda.md)
