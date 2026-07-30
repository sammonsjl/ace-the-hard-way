# Lab 15 — The gateway

## What you will have at the end

The platform gateway (**jewel**) built from source, running under supervisord as **two programs**: uwsgi (REST, :8080) and the **gRPC control plane** (:50051) — plus **envoy** from the release binary with a hand-written bootstrap config, polling the gateway for routes via xDS. No routes exist yet; that's Lab 16.

```
(Lab 16 opens :8443) ── envoy ──┬── xDS REST poll, 5s ──► gateway uwsgi :8080
                                └── gRPC (auth checks) ──► gateway control plane :50051
                                     both clusters static; listeners/routes arrive as DB rows
```

The *shape* below — paths, ports, process model, init order — is settled. What can shift under you is the jewel *source build* itself:

> **Here be dragons — still.** Jewel lives at [ansible/jewel](https://github.com/ansible/jewel): no releases, moving daily. The end state below is right, but requirements layout and module paths in the source tree may drift. When the repo disagrees with a build step, the repo wins — note the difference. And remember: Labs 1–14 already work. If jewel turns to quicksand, stop and ship.

All commands on **ace-control**.

## Layout

The gateway runs as its own **`gateway`** user (not `awx`), config lives in **`/etc/ansible-automation-platform/gateway/`**, uwsgi on **8080**, gRPC on **50051**, envoy fronting on 443 in production — **8443 here**, because nginx owns 443 on this shared box (a production deployment gives the gateway its own machine). The config path is the one jewel's own `settings.py` looks for, so we keep it as-is — same reasoning as AWX's `/etc/tower`:

```bash
sudo useradd --system --home-dir /var/lib/ansible-automation-platform --create-home --shell /bin/bash gateway
sudo install -d -o gateway -g gateway -m 0750 /etc/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway /var/log/ansible-automation-platform
sudo chmod 0755 /var/lib/ansible-automation-platform
```

## Database

Same moves as Lab 3 — a role and a database:

```bash
sudo -iu postgres createuser --pwprompt gateway     # pick a password, record it
sudo -iu postgres createdb --owner=gateway gateway
sudo -iu postgres psql -c '\l gateway'              # want: gateway | gateway
```

## Extra build toolchain (the gateway needs more than the controller)

The gateway does SAML/federation, which pulls in `python3-saml` → `xmlsec`, and `xmlsec` compiles against native libraries the controller build never needed. They live in **EPEL** and **CRB** (CodeReady Builder), so enable both first. (EPEL being enabled is harmless here — the [Appendix A1](a1-epel-uwsgi-conflict.md) uwsgi trap only bites if you `dnf install uwsgi`; every uwsgi in this tutorial is pip-installed in a venv.)

```bash
sudo dnf -y install epel-release
sudo dnf config-manager --set-enabled crb
sudo dnf -y install libxml2-devel xmlsec1-devel xmlsec1-openssl-devel libtool-ltdl-devel
```

> Skip these and the build dies deep in a wheel compile with `error: failed-wheel-build-for-install ... Failed to build installable wheels for some pyproject.toml based projects: xmlsec`. The traceback names `xmlsec`, not the missing `-devel`, so it reads like a Python problem when it's a system-library one.

## Clone and build

```bash
sudo install -d -o gateway -g gateway /opt/jewel
sudo -u gateway git clone https://github.com/ansible/jewel.git /opt/jewel
sudo -u gateway git -C /opt/jewel rev-parse --short HEAD   # RECORD THIS — no tags exist to pin

sudo -u gateway python3.12 -m venv /var/lib/ansible-automation-platform/venv/gateway
sudo -u gateway bash <<'EOF'
set -euo pipefail
source /var/lib/ansible-automation-platform/venv/gateway/bin/activate
cd /opt/jewel
pip install --upgrade pip setuptools wheel setuptools_scm
# jewel splits frozen deps and git deps, same as AWX — install both in one resolve:
cat requirements/requirements.txt requirements/requirements_git.txt | pip install -r /dev/stdin
pip install -e .
pip install uwsgi supervisor
EOF
```

The manage entrypoint jewel installs is **`aap-gateway-manage`** — that's the console script name in its own packaging, so it's what every command below calls. Give it a `/usr/bin` PATH wrapper (same trick as Lab 5's `awx-manage`), and bake in `OPENSSL_armcap=0`:

```bash
ls /var/lib/ansible-automation-platform/venv/gateway/bin/ | grep -i manage   # confirm the name
sudo tee /usr/bin/aap-gateway-manage >/dev/null <<'EOF'
#!/bin/bash
# hand-written PATH wrapper for the venv's aap-gateway-manage.
# OPENSSL_armcap=0: the gateway imports cryptography at startup; on an aarch64 VM
# under a hypervisor OpenSSL takes an accelerated code path that SIGILLs (exit 132) —
# the same trap as Lab 11's EEs, but here in a bare-metal process. Harmless on x86_64.
export OPENSSL_armcap=0
exec /var/lib/ansible-automation-platform/venv/gateway/bin/aap-gateway-manage "$@"
EOF
sudo chmod 0755 /usr/bin/aap-gateway-manage
```

> **Apple Silicon war story, reprise.** On an aarch64 VM the very first `aap-gateway-manage` command you run (the migrate below) exits **132** with no traceback — `rc=132`, silence. It's Lab 11's `OPENSSL_armcap` SIGILL again: the gateway imports `cryptography` (for JWT/SAML) before it prints anything, OpenSSL autodetects CPU crypto features that trap under the hypervisor, and the process dies. Unlike Lab 11 (where the trap was inside an EE *container*, fixed via `AWX_TASK_ENV`), here it's the gateway's own Python process — so the variable has to be in the wrapper (above), in `uwsgi.ini`, and in each supervisord program's `environment=` (all done below). x86_64 readers never see this and the variable is a no-op for them.

## Settings — the override file

Jewel loads `/etc/ansible-automation-platform/gateway/settings.py` automatically — `settings.py` in the source calls `load_python_file_with_injected_context('{etc}/settings.py')`, and `{etc}` is `/etc/ansible-automation-platform/gateway/`. So an override file at that path is picked up with no settings-module env var. The one we write carries the database, the redis cache, `STATIC_ROOT`, the gRPC port, and the trusted origin:

```bash
sudo -u gateway bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/ansible-automation-platform/gateway/SECRET_KEY'
sudo chmod 0400 /etc/ansible-automation-platform/gateway/SECRET_KEY

sudo -u gateway tee /etc/ansible-automation-platform/gateway/settings.py >/dev/null <<'EOF'
# Gateway override settings (hand-written for this lab:
# local postgres + unix-socket redis, no TLS on redis)

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'gateway',
        'USER': 'gateway',
        'PASSWORD': 'CHANGE-ME',
        'HOST': 'localhost',
        'PORT': 5432,
    }
}

# Jewel's default cache already points at a unix socket (db 4). Its 'primary'
# cache, though, uses a DAB redis client that assumes TLS + a dedicated redis
# host — wrong for our single-box socket. Replace it with a plain django_redis
# client on the same socket. (A multi-host deployment would use rediss:// +
# client certs here instead.)
CACHES['primary'] = {
    'BACKEND': 'django_redis.cache.RedisCache',
    'LOCATION': 'unix:///var/run/redis/redis.sock?db=4',
    'KEY_PREFIX': 'gateway',
    'OPTIONS': {'CLIENT_CLASS': 'django_redis.client.DefaultClient'},
}

# jewel's default STATIC_ROOT is an unwritable /opt path; point it at the
# platform UI dir (nginx serves this dir; collectstatic writes it below).
STATIC_ROOT = '/var/lib/ansible-automation-platform/platform/ui/static'

GRPC_SERVER_PORT = '50051'

CSRF_TRUSTED_ORIGINS = ['https://192.168.56.10:8443']
FRONT_END_URL = 'https://192.168.56.10:8443'
EOF
sudo vim /etc/ansible-automation-platform/gateway/settings.py   # real DB password
```

> The gateway user needs to reach the Lab 4 redis socket: `sudo usermod -aG redis gateway` — the same group trick Lab 4 used for awx.
>
> The SECRET_KEY needs no setting line — jewel's `set_secret_key` defaults `SECRET_KEY_FILE` to exactly `{etc}/SECRET_KEY`, which is where we just wrote it. (You *can* set `GATEWAY_SECRET_KEY_FILE` explicitly, but the default already matches, so we skip it.)

## Init chain

Migrate → superuser → collectstatic. The `authenticators --initialize` step comes *later*, after the services are up — it needs a running gateway, so it's below. The superuser password rides an env var rather than a prompt, so the step is scriptable:

```bash
sudo -u gateway aap-gateway-manage migrate

sudo -u gateway bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-gateway-manage createsuperuser --username=admin --email=admin@example.com --noinput'
```

Now the static files. `STATIC_ROOT` is owned **root:nginx** and `collectstatic` runs as **root** (not `gateway`) — nginx only ever *reads* this tree, so nothing needs write access at runtime. Create the directory, then collect as root (the wrapper still supplies `OPENSSL_armcap=0`):

```bash
sudo install -d -o root -g nginx -m 0755 /var/lib/ansible-automation-platform/platform/ui/static
sudo bash -c 'umask 022 && aap-gateway-manage collectstatic --noinput --clear'
```

> Run `collectstatic` as `gateway` and it dies with `PermissionError: [Errno 13] Permission denied: '.../static/admin'` the moment it tries to write into the root-owned tree. Running the whole step as root sidesteps it.

## Run it: supervisord, two programs

The gateway is another supervisord family — `uwsgi` plus `aap-gateway-manage start_grpc_server`, both as `gateway`, one systemd unit on top (`automation-gateway.service`):

The uwsgi config binds **two** sockets: a uwsgi-protocol socket on `8050` (there for an nginx front, if you ever want one) and an `http-socket` on `8080` that envoy talks to directly — envoy speaks HTTP, so we skip the extra nginx layer for the gateway entirely. `DJANGO_SETTINGS_MODULE` and `mount` wire up the WSGI app, and `OPENSSL_armcap=0` is the SIGILL fix inside the worker:

```bash
sudo -u gateway tee /etc/ansible-automation-platform/gateway/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
uid = gateway
socket = 127.0.0.1:8050
http-socket = 127.0.0.1:8080
processes = 2
buffer-size = 10240
master = true
vacuum = true
no-orphans = true
lazy-apps = true
manage-script-name = true
env = DJANGO_SETTINGS_MODULE=aap_gateway_api.settings
env = OPENSSL_armcap=0
mount = /=aap_gateway_api.wsgi:application
harakiri = 120
py-call-osafterfork = true
EOF

sudo tee /etc/ansible-automation-platform/gateway/supervisord.conf >/dev/null <<'EOF'
[unix_http_server]
file=/var/run/ansible-automation-platform/supervisor.sock

[supervisord]
umask = 022
minfds = 4096
logfile=/var/log/ansible-automation-platform/supervisord.log
pidfile=/var/run/ansible-automation-platform/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/ansible-automation-platform/supervisor.sock

[program:uwsgi]
command=/var/lib/ansible-automation-platform/venv/gateway/bin/uwsgi /etc/ansible-automation-platform/gateway/uwsgi.ini
user=gateway
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/ansible-automation-platform/uwsgi.log
environment=OPENSSL_armcap="0"

[program:control-plane]
command=/var/lib/ansible-automation-platform/venv/gateway/bin/aap-gateway-manage start_grpc_server
user=gateway
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/ansible-automation-platform/control-plane.log
environment=OPENSSL_armcap="0"

[group:automation-gateway]
programs=uwsgi,control-plane
priority=5
EOF

sudo tee /etc/tmpfiles.d/aap-gateway.conf >/dev/null <<'EOF'
D /var/run/ansible-automation-platform 0750 gateway gateway -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/aap-gateway.conf

sudo tee /etc/systemd/system/automation-gateway.service >/dev/null <<'EOF'
[Unit]
Description=ACE platform gateway (supervisord: uwsgi + gRPC control plane)
After=network.target postgresql.service redis.service
Wants=postgresql.service redis.service

[Service]
Type=simple
ExecStart=/var/lib/ansible-automation-platform/venv/gateway/bin/supervisord -n -c /etc/ansible-automation-platform/gateway/supervisord.conf
ExecStop=/var/lib/ansible-automation-platform/venv/gateway/bin/supervisorctl -c /etc/ansible-automation-platform/gateway/supervisord.conf shutdown
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo semanage fcontext -a -t bin_t '/var/lib/ansible-automation-platform/venv/gateway/bin(/.*)?'   # Lab 8's 203/EXEC fix
sudo restorecon -Rv /var/lib/ansible-automation-platform/venv/gateway/bin
sudo systemctl daemon-reload
sudo systemctl enable --now automation-gateway

sudo /var/lib/ansible-automation-platform/venv/gateway/bin/supervisorctl \
  -c /etc/ansible-automation-platform/gateway/supervisord.conf status
# want: automation-gateway:uwsgi and automation-gateway:control-plane both RUNNING

curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: {"status":"good", ..., "db_connected":true, ...} — direct, no proxy yet
# (dispatcherd_connected:false is expected — the gateway's own task dispatcher
#  isn't wired here and isn't needed for the proxy path.)
```

## The gateway's front-door cert (signed by the Lab 10 web CA)

envoy terminates TLS on the platform port, and jewel's default listener config points at `/etc/ansible-automation-platform/gateway/gateway.crt` + `gateway.key`. Nothing creates them yet, and without them envoy **rejects the listener** the moment Lab 16 registers it (`Failed to load incomplete private key`). Sign one now with the **Lab 10 web CA** — this is exactly what the doc promised back in Lab 10 ("the web CA built here signs the gateway's front door later"). The `localhost` SAN matters: the gateway calls *itself* at `localhost:8443` during Lab 16's data migration, and the cert has to be valid for that name too.

```bash
sudo openssl genrsa -out /etc/ansible-automation-platform/gateway/gateway.key 2048
sudo openssl req -new -key /etc/ansible-automation-platform/gateway/gateway.key \
  -subj "/CN=ace-control" -out /tmp/gw.csr
printf "subjectAltName=DNS:ace-control,DNS:localhost,IP:192.168.56.10,IP:127.0.0.1\n" \
  | sudo tee /tmp/gw_ext.cnf >/dev/null
sudo openssl x509 -req -in /tmp/gw.csr \
  -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key -CAcreateserial \
  -days 825 -sha256 -out /etc/ansible-automation-platform/gateway/gateway.crt \
  -extfile /tmp/gw_ext.cnf
sudo chown gateway:gateway /etc/ansible-automation-platform/gateway/gateway.key \
  /etc/ansible-automation-platform/gateway/gateway.crt
sudo chmod 0640 /etc/ansible-automation-platform/gateway/gateway.key
sudo rm -f /tmp/gw.csr /tmp/gw_ext.cnf
```

## envoy from the release binary

Another real tarball moment. Pinned: **v1.38.3** (asset naming quirk: `aarch_64`, with an underscore):

```bash
ENVOY_VERSION=1.38.3
ARCH=$(uname -m); case $ARCH in x86_64) EARCH=x86_64 ;; aarch64) EARCH=aarch_64 ;; esac
curl -fsSL -o /tmp/envoy \
  "https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-${EARCH}"
sudo install -m 0755 /tmp/envoy /usr/local/bin/envoy
envoy --version    # want: 1.38.3
```

## envoy bootstrap — by hand

The bootstrap needs **two static clusters** — the REST control plane (HTTP/1, where LDS/CDS poll every 5s) and the **gRPC control plane** (HTTP/2, :50051 — jewel authenticates proxied requests through it). Everything else arrives via xDS from database rows:

```bash
sudo install -d -m 0755 /etc/envoy
sudo tee /etc/envoy/envoy.yaml >/dev/null <<'EOF'
node:
  id: envoy-gateway-1
  cluster: envoy

dynamic_resources:
  cds_config:
    resource_api_version: V3
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: { seconds: 5 }
      request_timeout: { seconds: 5 }
  lds_config:
    resource_api_version: V3
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: { seconds: 5 }
      request_timeout: { seconds: 5 }

static_resources:
  clusters:
    - name: gateway-control-plane-rest
      type: STRICT_DNS
      connect_timeout: 5s
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http_protocol_options: {}
      load_assignment:
        cluster_name: gateway-control-plane-rest
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 8080 }

    - name: gateway_control_plane
      type: STRICT_DNS
      connect_timeout: 5s
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {}
      load_assignment:
        cluster_name: gateway_control_plane
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 50051 }

admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 19000 }
EOF
```

## The path-rewrite Lua script envoy expects

Jewel's generated listener config references a Lua script at `/etc/envoy/envoy-path-rewrite.lua` (it rewrites gateway paths like `/api/controller/` down to what the backend serves). It's shipped in the jewel tree — copy it into place, or envoy rejects the listener in Lab 16 with `Invalid path: /etc/envoy/envoy-path-rewrite.lua` and the platform port never opens:

```bash
sudo cp /opt/jewel/tools/scripts/envoy-path-rewrite.lua /etc/envoy/envoy-path-rewrite.lua
sudo chmod 0644 /etc/envoy/envoy-path-rewrite.lua
```

envoy gets its own service, `automation-gateway-proxy` — separate from the gateway itself, so you can restart the proxy without bouncing the app:

```bash
sudo tee /etc/systemd/system/automation-gateway-proxy.service >/dev/null <<'EOF'
[Unit]
Description=Envoy proxy for the ACE gateway
After=network.target automation-gateway.service
Wants=automation-gateway.service

[Service]
Type=simple
User=gateway
Group=gateway
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now automation-gateway-proxy
sudo firewall-cmd --permanent --add-port=8443/tcp && sudo firewall-cmd --reload
```

## Verify

```bash
systemctl is-active automation-gateway automation-gateway-proxy    # want: active, active

# envoy found both control-plane clusters…
curl -s http://127.0.0.1:19000/clusters | grep -E 'gateway.control.plane' | head -4

# …and is polling for routes that don't exist yet:
curl -s http://127.0.0.1:19000/config_dump | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("configs:", len(d["configs"]))'
```

Envoy up, polling, **no listeners** — an empty proxy waiting for a registry. That emptiness is the lesson: in this architecture, adding a route is an API call, not a config file. Lab 16 makes those calls.

Next: [Service registration](16-service-registration.md)
