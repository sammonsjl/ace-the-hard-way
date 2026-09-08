# Lab 9 — Event-Driven Ansible

## What this is

Event-Driven Ansible turns the platform from something you *tell* to run automation into something
that runs automation *because something happened*.

It is **eda-server**: an API and a set of workers that run **rulebooks** — sources that listen
(a webhook, a Kafka topic, an alert stream), conditions that match, and actions that fire. The
usual action is "launch a job template on the controller".

## Where it fits

This is the last component, and it is the one that closes the loop. The controller runs automation
on demand; EDA decides when demand exists.

```
   an event ──► eda-server rulebook ──► condition matches
                                              │
                                              └──► launches a job template
                                                   on ace-controller, through the gateway

   console ──► envoy :443 ──► /api/eda/ ──► ace-eda :443 nginx ──┬── API + websockets
                                                                 ├── scheduler
                                                                 └── activation workers
```

It depends on more of the platform than anything else: PostgreSQL on ace-db, Redis on ace-gateway,
the gateway for identity, and the controller as the thing it ultimately triggers. That makes it a
good last build — if EDA works, everything underneath it does.

## A note on names

Two conventions collide in this build, and it is worth knowing which is which.

**Paths follow the platform.** EDA's configuration lives in
`/etc/ansible-automation-platform/eda/` and its state in
`/var/lib/ansible-automation-platform/eda/` — the same layout the gateway uses, and the same one a
packaged install creates. It is deliberately *not* `/etc/eda`; components that belong to the
platform live under the platform's directory.

Hub is the exception that proves the rule: it keeps `/etc/pulp` and `/var/lib/pulp`, because those
are **pulpcore's own** upstream paths and a packaged install inherits them rather than moving pulp
somewhere else. Only hub's *logs* go to `/var/log/ansible-automation-platform/hub`.

**Unit names are ours.** A packaged install calls these
`automation-eda-controller-daphne.service`, `automation-eda-controller-scheduler.service` and so
on, driven by a `.target`. We use the shorter `automation-eda-*` because we build four services and
a packaged install builds seven — it also has activation workers and an event-stream listener, which
this tutorial does not cover. Rather than adopt a naming scheme for a service set we do not have,
the names say what they are. If you later add those services, renaming is the obvious first step.

## What you will have at the end

Event-Driven Ansible — **eda-server** — built from source, running as its systemd
service family (API, websockets, scheduler, worker), fronted by its own nginx, and
registered behind the gateway so `https://192.168.1.41/api/eda/…` authenticates
with the same platform login as the controller and the hub.

```
envoy :443 ──/api/eda/…──► nginx :443 ──┬── unix:/run/eda/eda-api.sock   (gunicorn, aap_eda.wsgi — REST API)
   (gateway JWT)                           └── unix:/run/eda/eda-ws.sock    (daphne, aap_eda.asgi — websockets)
                                           aap-eda-manage scheduler         (periodic)
                                           aap-eda-manage dispatcherd       (DefaultWorker — pg_notify tasking, like AWX)
```

All commands on **ace-eda** unless stated otherwise.

## Foundation

```bash
sudo useradd --system --home-dir /var/lib/ansible-automation-platform/eda --create-home --shell /bin/bash eda
sudo install -d -o eda -g eda /var/lib/ansible-automation-platform/eda /var/lib/ansible-automation-platform/eda/media /var/lib/ansible-automation-platform/eda/static /etc/ansible-automation-platform/eda
```

The database role already exists — [Lab 4](04-postgresql.md) created all four up front. Confirm
this node can reach it before building anything:

```bash
sudo dnf -y install postgresql
PGPASSWORD='CHANGE-ME-eda' psql -h ace-db -U eda -d eda -c 'SELECT 1'
```

There is no `usermod -aG redis` here, because redis is on **ace-gateway** — this is the one
component that reaches the cache across the network, and the next section opens that path.

## Build toolchain

Same native-build story as the gateway and the controller — `cryptography`, `psycopg`, and
`python-ldap` (pulled in through DAB's authentication extras) all compile against system headers.
This box has neither Python 3.12 nor a compiler yet; every other component's lab installs its own
toolchain explicitly, and EDA is no exception even though it is easy to reach this step assuming
`python3.12` is already there:

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel
python3.12 --version
```

## Clone and build

`eda-server` is a poetry project, but a plain `pip install .` reads its `pyproject.toml`
and resolves everything (DAB devel, Django 5.2, channels/daphne, dispatcherd):

```bash
sudo install -d -o eda -g eda /opt/eda-server
sudo -u eda git clone https://github.com/ansible/eda-server.git /opt/eda-server
sudo -u eda git -C /opt/eda-server rev-parse --short HEAD

sudo -u eda python3.12 -m venv /var/lib/ansible-automation-platform/eda/venv
sudo -u eda bash <<'EOF'
set -euo pipefail
source /var/lib/ansible-automation-platform/eda/venv/bin/activate
pip install --upgrade pip setuptools wheel
cd /opt/eda-server
pip install . gunicorn
pip install ansible-runner ansible-core ansible-rulebook
pip list | grep -iE 'aap-eda|django-ansible-base|django |channels|daphne'
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
export EDA_SETTINGS_FILE=/etc/ansible-automation-platform/eda/settings.yaml
export PATH=/var/lib/ansible-automation-platform/eda/venv/bin:$PATH
exec /var/lib/ansible-automation-platform/eda/venv/bin/aap-eda-manage "$@"
EOF
sudo chmod 0755 /usr/bin/aap-eda-manage
```

## Settings — `/etc/ansible-automation-platform/eda/settings.yaml`

eda-server reads a dynaconf YAML (`EDA_SETTINGS_FILE`, defaulting to `/etc/ansible-automation-platform/eda/settings.yaml`):

```bash
sudo -u eda bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/ansible-automation-platform/eda/SECRET_KEY'
sudo chmod 0400 /etc/ansible-automation-platform/eda/SECRET_KEY

sudo tee /etc/ansible-automation-platform/eda/settings.yaml >/dev/null <<'EOF'
SECRET_KEY_FILE: /etc/ansible-automation-platform/eda/SECRET_KEY
ALLOWED_HOSTS: "*"
DATABASES:
  default:
    ENGINE: django.db.backends.postgresql
    NAME: eda
    USER: eda
    PASSWORD: CHANGE-ME
    HOST: ace-db
    PORT: 5432
MEDIA_ROOT: /var/lib/ansible-automation-platform/eda/media
STATIC_ROOT: /var/lib/ansible-automation-platform/eda/static
STATIC_URL: /api/eda/static/
DEPLOYMENT_TYPE: podman
MQ_HOST: ace-gateway
MQ_PORT: 6379
MQ_DB: 5
# gateway integration (JWT consumer)
ANSIBLE_BASE_JWT_KEY: https://192.168.1.41
ANSIBLE_BASE_JWT_VALIDATE_CERT: false
ANSIBLE_BASE_JWT_REDIRECT_TYPE: eda
ANSIBLE_BASE_MANAGED_ROLE_REGISTRY:
  platform_auditor:
    name: Platform Auditor
    shortname: sys_auditor
ENABLE_SERVICE_BACKED_SSO: false
WEBSOCKET_BASE_URL: wss://192.168.1.44   # this node — ace-eda serves its own websocket
WEBSOCKET_SSL_VERIFY: "no"
EOF
sudo chown eda:eda /etc/ansible-automation-platform/eda/settings.yaml
sudo chmod 0640 /etc/ansible-automation-platform/eda/settings.yaml
sudo vim /etc/ansible-automation-platform/eda/settings.yaml
```

## Redis

EDA addresses redis by **host:port** for its channels and websocket layer.
[Lab 6](06-controller.md) turned that port on, but it opened it to **one address** — the
controller's. This node is not that address, so it needs its own rule.

**On `ace-gateway`:**

```bash
sudo firewall-cmd --permanent \
  --add-rich-rule='rule family=ipv4 source address=192.168.1.44/32 port port=6379 protocol=tcp accept'
sudo firewall-cmd --reload
```

**Back on `ace-eda`** — confirm the path before trusting it:

```bash
sudo dnf -y install valkey-compat-redis
redis-cli -h ace-gateway -p 6379 ping
```

`PONG` and you are done here.

> **One rule per consumer is the point, not an inconvenience.** This redis has no password: the
> firewall is the only thing in front of it, and these VMs are bridged onto your home LAN. Opening
> `192.168.1.0/24` once in Lab 6 would have saved this step and published an unauthenticated cache
> to every device you own.
>
> If `ping` times out, this rule is missing or names the wrong address; if it is *refused*, redis is
> still bound to loopback only, which is a Lab 6 problem rather than an EDA one.
>
> Note that EDA and hub use different redis **databases** (`/5` and `/2` in their settings) on the
> same server. That is not isolation in any security sense — anyone who can reach the port can
> select any database — it just stops the two components colliding on key names.

## Migrate, init, admin, static

```bash
sudo -u eda aap-eda-manage migrate
sudo -u eda aap-eda-manage create_initial_data
sudo -u eda bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-eda-manage createsuperuser --username admin --email admin@example.com --noinput'
sudo -u eda bash -c 'umask 022 && aap-eda-manage collectstatic --noinput --clear'
```

> `migrate` logs `RESOURCE_SERVER['SECRET_KEY'] is not configured. Reverse sync will not be
> enabled.` — expected. We add the secret when we wire the gateway, at the end of this lab.
>
> Note it is logged at **ERROR** level and repeats several times per command — including on
> `create_initial_data` and `createsuperuser` — so you will see a stack of red `ERROR` lines
> around output that is otherwise fine. Nothing is wrong; DAB is reporting a capability it cannot
> enable yet. It stops once the secret is in place.

## The service family (systemd)

Four units, one shared environment file. The workers use **dispatcherd** over pg_notify —
the same task engine as the controller ([Lab 6](06-controller.md)), no separate broker:

```bash
sudo tee /etc/tmpfiles.d/eda.conf >/dev/null <<'EOF'
d /run/eda 0755 eda eda -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/eda.conf

sudo tee /etc/default/eda >/dev/null <<'EOF'
OPENSSL_armcap=0
EDA_SETTINGS_FILE=/etc/ansible-automation-platform/eda/settings.yaml
PATH=/var/lib/ansible-automation-platform/eda/venv/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin
EOF

VENV=/var/lib/ansible-automation-platform/eda/venv/bin

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

sudo tee /etc/systemd/system/automation-eda-activation-worker.service >/dev/null <<EOF
[Unit]
Description=EDA activation worker (dispatcherd)
After=network-online.target postgresql.service redis.service
Wants=network-online.target
[Service]
EnvironmentFile=/etc/default/eda
User=eda
Group=eda
ExecStart=${VENV}/aap-eda-manage dispatcherd --worker-class ActivationWorker
Restart=always
RestartSec=3
[Install]
WantedBy=multi-user.target
EOF

sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/ansible-automation-platform/eda/venv/bin(/.*)?'
sudo restorecon -Rv /var/lib/ansible-automation-platform/eda/venv/bin
sudo systemctl daemon-reload
sudo systemctl enable --now automation-eda-api automation-eda-ws automation-eda-scheduler \
  automation-eda-default-worker automation-eda-activation-worker

curl -s --unix-socket /run/eda/eda-api.sock http://localhost/api/eda/v1/status/

> **Two workers, not one, and the status endpoint is what tells you.** `dispatcherd` takes a
> `--worker-class` of either `DefaultWorker` or `ActivationWorker`, and EDA needs both: the default
> worker drains the general task queue, the activation worker runs rulebook activations. Start only
> the default one and everything looks fine — all units `active`, the API answering `200` — while
> `/api/eda/v1/status/` quietly reports:
>
> ```json
> {"status":"degraded","message":"Dispatcherd workers unavailable"}
> ```
>
> The reason is one line in the API's log, and it names the queue rather than the unit:
> `Worker queue [activation] was found to not be healthy`. With both workers running the endpoint
> returns `{"status":"good"}`, and that is the check to trust — `systemctl is-active` cannot see
> this.
```

> **`{"status": "degraded", "message": "Dispatcherd workers unavailable"}` is the correct, permanent
> answer here — not a startup race that clears on its own.** `check_dispatcherd_workers_health()`
> in `aap_eda/core/health.py` requires *both* the default worker above and an activation worker
> listening on `RULEBOOK_WORKER_QUEUES` (`activation`, by default) before it reports healthy. This
> lab intentionally does not run an `ActivationWorker` — see the note right below — so the second
> half of that check fails every time it is asked, not only in the few seconds after start.
> `journalctl -u automation-eda-default-worker` will still show `pg_notify … established` and real
> tasks running: the default worker is genuinely healthy, and `degraded` is EDA accurately
> reporting that it can register with the platform but cannot run a rulebook activation — which
> stays true until the fifth unit below exists.

> **Production note:** the full EDA also runs an **ActivationWorker**
> (`aap-eda-manage dispatcherd --worker-class ActivationWorker`), which launches rulebook
> activations as podman containers — the decision-environment equivalent of the controller's
> EEs. Add it as a fifth unit when you want to run activations; the API, scheduler, and
> default worker above are enough to bring EDA up and register it with the platform.

## nginx

**On `ace-eda`:**

```bash
sudo /usr/local/sbin/ace-request-cert server /etc/ansible-automation-platform/eda eda cert
```

**On `ace-gateway`:**

```bash
sudo /usr/local/sbin/ace-sign-request ace-eda-server cert
```

**Back on `ace-eda`:**

```bash
sudo install -o root -g eda -m 0644 /srv/ace/ace-eda-server.cert \
  /etc/ansible-automation-platform/eda/server.cert
sudo rm -f /srv/ace/ace-eda-server.cert
sudo openssl verify /etc/ansible-automation-platform/eda/server.cert

sudo dnf -y install nginx
sudo setsebool -P httpd_can_network_connect on

sudo tee /etc/nginx/conf.d/automation-eda-controller-api.conf >/dev/null <<'EOF'
upstream eda-api { server unix:/run/eda/eda-api.sock; }
upstream eda-ws  { server unix:/run/eda/eda-ws.sock; }
server {
    listen 443 ssl default_server;
    server_name _;
    ssl_certificate     /etc/ansible-automation-platform/eda/server.cert;
    ssl_certificate_key /etc/ansible-automation-platform/eda/server.key;
    ssl_ciphers         PROFILE=SYSTEM;
    client_max_body_size 20m;
    root /var/lib/ansible-automation-platform/eda/static;
    location /api/eda/ws/ {
        proxy_pass http://eda-ws;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection "upgrade";
        proxy_set_header Host $http_host;
    }
    location /api/eda/static/ { alias /var/lib/ansible-automation-platform/eda/static/; }
    location / {
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://eda-api;
        proxy_read_timeout 120s;
    }
}
EOF

sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=443/tcp && sudo firewall-cmd --reload
```

> Same as [Lab 8](08-hub.md): firewalld is not installed on this box, so the install line is not
> optional — without it `firewall-cmd` is `command not found`.

nginx reaches the API over a unix socket, and that crosses the same pair of SELinux checks
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
curl -sk https://127.0.0.1:443/api/eda/v1/status/ -o /dev/null -w "eda via nginx: %{http_code}\n"
```

> Skip the module and you get a **502** with `connect() to unix:/run/eda/eda-api.sock failed
> (13: Permission denied)` in `/var/log/nginx/error.log` — while `ausearch` reports *nothing*,
> because the `sock_file` denial sits behind a `dontaudit` rule. The socket is mode 0777; it was
> never a permissions problem.

## Register behind the gateway

Same REST-with-PKs pattern as everything before it. Reuse [Lab 8](08-hub.md)'s `register.py`
helpers — swap its hub rows for these, or append these to a copy. One EDA cluster/node/service,
then the service secret:

```python
st  = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}
hp  = find("/http_ports/", "API Port")
eda = ensure("/service_clusters/", "eda", {"name": "eda", "service_type": st["eda"]})
ensure("/service_nodes/", "Node eda - ace-eda",
       {"name": "Node eda - ace-eda", "address": "192.168.1.44", "service_cluster": eda, "tags": "api"})
ensure("/services/", "eda api",
       {"name": "eda api", "api_slug": "eda", "http_port": hp, "service_cluster": eda,
        "is_service_https": True, "service_path": "/api/eda/", "service_port": 443,
        "order": 3, "node_tags": "api"})
```

```bash
sudo -u gateway aap-gateway-manage generate_service_secret eda

sudo tee -a /etc/ansible-automation-platform/eda/settings.yaml >/dev/null <<'EOF'
RESOURCE_SERVER:
  URL: https://192.168.1.41
  SECRET_KEY: PASTE-THE-EDA-SECRET
  VALIDATE_HTTPS: false
EOF
sudo vim /etc/ansible-automation-platform/eda/settings.yaml
sudo systemctl restart automation-eda-api automation-eda-default-worker automation-eda-activation-worker
```

## Verify — EDA through the platform door

> **Expect a 503 for the first ~45 seconds.** envoy actively health-checks each backend, and a
> node stays out of rotation until the checks pass consistently — so the restart you just did puts
> EDA briefly out of service *through the gateway* even though `curl -sk https://ace-eda/...`
> answers 200 locally. Watch it flip rather than guessing:
> ```bash
> curl -s "http://127.0.0.1:19000/stats?filter=cluster-.*-443-nodes_api" | grep membership_healthy
> ```
> `membership_total: 1` with `membership_healthy: 0` means registration worked and the health check
> has not passed yet — a different problem from an empty cluster, which would mean the node tag on
> the service and the node disagree.

```bash
curl -sk https://192.168.1.41/api/eda/v1/status/ -o /dev/null -w "status: %{http_code}\n"

curl -sk -u "admin:CHANGE-ME" https://192.168.1.41/api/eda/v1/users/me/ \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["username"], d["is_superuser"], d["resource"]["resource_type"])'
```

That `shared.user` resource type is the whole platform speaking one identity: the same admin,
proven by the gateway, accepted by the controller, the hub, and EDA alike — each built by hand
from source.

## The payoff — the console is complete

Refresh the platform UI at **`https://192.168.1.41`** one last time. **Automation Decisions**
joins Automation Execution and Automation Content, and the navigation you saw in Lab 7 with a
single entry is now the full platform — one login reaching three services you built from source,
on three different Python versions, sharing one identity.

Again: no UI rebuild. Three registry entries, three envoy routes, one console.

Back to the [README](../README.md) — you built an automation platform, every service and its
console, by hand.
