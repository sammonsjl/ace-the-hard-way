# Lab 15 — The gateway

## What you will have at the end

The platform gateway (**jewel**) built from source, running the bundle's exact process topology — supervisord with **two programs**: uwsgi (REST, :8080) and the **gRPC control plane** (:50051) — plus **envoy** from the release binary with the bundle's bootstrap config, polling the gateway for routes via xDS. No routes exist yet; that's Lab 16.

```
(Lab 16 opens :8443) ── envoy ──┬── xDS REST poll, 5s ──► gateway uwsgi :8080
                                └── gRPC (auth checks) ──► gateway control plane :50051
                                     both clusters static; listeners/routes arrive as DB rows
```

This lab's *shape* is now **verified against the 2.6 bundle's `automationgateway` role** — paths, ports, process model, init order. What remains unverifiable ahead of time is the jewel *source build* itself:

> **Here be dragons — still.** Jewel lives at [ansible/jewel](https://github.com/ansible/jewel): no releases, moving daily. The bundle installs RPMs of this same app, so the end state below is right, but requirements layout and module paths in the source tree may drift. When the repo disagrees with a build step, the repo wins — note the difference. And remember: Labs 1–14 already work. If jewel turns to quicksand, stop and ship.

All commands on **ace-control**.

## Layout (bundle paths, our build)

Verified: the gateway runs as its own **`gateway`** user (not `awx`), config lives in **`/etc/ansible-automation-platform/gateway/`**, uwsgi on **8080**, gRPC on **50051**, envoy fronting on 443 in production — **8443 here**, because nginx owns 443 on this shared box (real installs put the gateway on its own machine). We keep the real config path for downstream fidelity, same reasoning as `/etc/tower`:

```bash
sudo useradd --system --home-dir /var/lib/ansible-automation-platform --create-home --shell /bin/bash gateway
sudo install -d -o gateway -g gateway -m 0750 /etc/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway /var/log/ansible-automation-platform
sudo chmod 0755 /var/lib/ansible-automation-platform
```

## Database

Same moves as Lab 3 — a role and a database:

```bash
sudo -u postgres createuser --pwprompt gateway     # pick a password, record it
sudo -u postgres createdb --owner=gateway gateway
sudo -u postgres psql -c '\l gateway'              # want: gateway | gateway
```

## Clone and build

```bash
sudo install -d -o gateway -g gateway /opt/jewel
sudo -u gateway git clone https://github.com/ansible/jewel.git /opt/jewel
git -C /opt/jewel rev-parse --short HEAD           # RECORD THIS — no tags exist to pin

sudo -u gateway python3.12 -m venv /var/lib/ansible-automation-platform/venv/gateway
sudo -u gateway bash <<'EOF'
set -euo pipefail
source /var/lib/ansible-automation-platform/venv/gateway/bin/activate
cd /opt/jewel
pip install --upgrade pip setuptools wheel
# the requirements layout is the repo's to define — look before you pip:
ls requirements* 2>/dev/null; ls requirements/ 2>/dev/null || true
pip install -r requirements/requirements.txt       # adjust to what ls showed
pip install -e .
pip install uwsgi supervisor
EOF
```

The manage entrypoint is **`aap-gateway-manage`** — both the bundle and the gateway operator call exactly that. Give it the RPM-style PATH wrapper (same trick as Lab 5's `awx-manage`):

```bash
ls /var/lib/ansible-automation-platform/venv/gateway/bin/ | grep -i manage   # confirm the name
sudo tee /usr/bin/aap-gateway-manage >/dev/null <<'EOF'
#!/bin/bash
exec /var/lib/ansible-automation-platform/venv/gateway/bin/aap-gateway-manage "$@"
EOF
sudo chmod 0755 /usr/bin/aap-gateway-manage
```

## Settings — the bundle's override file

Verified shape: one `settings.py` override in the config dir carrying the database, the redis cache, the SECRET_KEY file pointer, the gRPC port, and the trusted origin. Ours adapts redis to Lab 4's unix socket:

```bash
sudo -u gateway bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/ansible-automation-platform/gateway/SECRET_KEY'
sudo chmod 0400 /etc/ansible-automation-platform/gateway/SECRET_KEY

sudo -u gateway tee /etc/ansible-automation-platform/gateway/settings.py >/dev/null <<'EOF'
# Gateway override settings (mirrors the bundle's settings.py.j2 shape)

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

# Lab 4 redis, unix socket (the bundle uses TCP+TLS on dedicated redis nodes;
# check the repo's default CACHES shape and adapt keys if they differ)
CACHES['primary']['LOCATION'] = 'unix:///var/run/redis/redis.sock?db=2'

GATEWAY_SECRET_KEY_FILE = "/etc/ansible-automation-platform/gateway/SECRET_KEY"
GRPC_SERVER_PORT = '50051'

CSRF_TRUSTED_ORIGINS = ['https://192.168.56.10:8443']
FRONT_END_URL = 'https://192.168.56.10:8443'
EOF
sudo vim /etc/ansible-automation-platform/gateway/settings.py   # real DB password
```

> The gateway user needs to reach the Lab 4 redis socket: `sudo usermod -aG redis gateway` (the bundle does the same group trick for awx).

## Init chain (the bundle's exact order)

Migrate → collectstatic → initialize the local authenticator → superuser. All as `gateway`; the superuser password rides an env var, exactly like the installer:

```bash
sudo -u gateway aap-gateway-manage migrate
sudo -u gateway bash -c 'umask 022 && aap-gateway-manage collectstatic --noinput --clear'
sudo -u gateway aap-gateway-manage authenticators --initialize
sudo -u gateway bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-gateway-manage createsuperuser --username=admin --email=admin@example.com --noinput'
```

(If the source tree wants a settings-module env var to find `/etc/ansible-automation-platform/gateway/settings.py`, the repo's docs/wsgi module will say — wire it into the wrapper script so every later command inherits it.)

## Run it: supervisord, two programs

Verified: the gateway is another supervisord family — `uwsgi` plus `aap-gateway-manage start_grpc_server`, both as `gateway`, one systemd unit on top (`automation-gateway.service`):

```bash
sudo -u gateway tee /etc/ansible-automation-platform/gateway/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
http-socket = 127.0.0.1:8080
chdir = /opt/jewel
module = aap_gateway_api.wsgi:application    ; verify the module path in the repo
home = /var/lib/ansible-automation-platform/venv/gateway
master = true
processes = 2
harakiri = 120
vacuum = true
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

[program:control-plane]
command=/usr/bin/aap-gateway-manage start_grpc_server
user=gateway
autostart=true
autorestart=true
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/ansible-automation-platform/control-plane.log

[group:gateway]
programs=uwsgi,control-plane
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

curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: JSON pong from the gateway, direct — no proxy yet
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

## envoy bootstrap — the bundle's, by hand

Verified against `envoy.yaml.j2`: **two static clusters** — the REST control plane (HTTP/1, where LDS/CDS poll every 5s) and the **gRPC control plane** (HTTP/2, :50051 — jewel authenticates proxied requests through it). Everything else arrives via xDS from database rows:

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

The bundle runs envoy as its own service, `automation-gateway-proxy`:

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
