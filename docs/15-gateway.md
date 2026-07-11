# Lab 15 — The gateway

## What you will have at the end

The platform gateway (**jewel**) built from source in its own venv, database migrated, admin created, uwsgi answering on `127.0.0.1:8080` — and **envoy** from the release binary in front of it, bootstrap config written by hand, polling jewel for its routes via xDS. No routes exist yet; that's Lab 16.

```
(Lab 16 will open :8443) ── envoy ──┬── xDS poll every 5s ──► jewel :8080 (REST control plane)
                                    └── routes/clusters arrive as DB rows, not config files
```

> **Here be dragons — read before starting.** Jewel lives at [ansible/jewel](https://github.com/ansible/jewel): no releases, no packages, a dev repo that moves daily and has broken before (the docker-compose quickstart was broken for weeks in 2026). This lab is an expedition map, not verified terrain: the *shape* (venv build → settings → migrate → init chain → uwsgi → envoy) is solid; exact file names, settings keys, and manage commands may have drifted by the time you run it. When the repo disagrees with this lab, **the repo wins** — note the difference, it's tutorial material. And remember the milestone note: Labs 1–14 already work. If jewel turns to quicksand, stop and ship.

All commands on **ace-control**.

## Layout decisions (documented)

Same treatment as AWX, parallel everything: source at `/opt/jewel`, venv at `/var/lib/awx/venv/jewel`, config at `/etc/jewel`, running as `awx`. Its own `jewel` database in the Lab 3 postgres; redis over the Lab 4 socket. The platform door will be **:8443** — nginx keeps :443, because on a single box the controller and gateway can't both own it (on real multi-node AAP they're different machines).

## Database

Same moves as Lab 3 — a role and a database:

```bash
sudo -u postgres createuser --pwprompt jewel     # pick a password, record it
sudo -u postgres createdb --owner=jewel jewel
sudo -u postgres psql -c '\l jewel'              # want: jewel | jewel
```

## Clone and build

```bash
sudo install -d -o awx -g awx /opt/jewel
sudo -u awx git clone https://github.com/ansible/jewel.git /opt/jewel
git -C /opt/jewel rev-parse --short HEAD         # RECORD THIS — no tags exist to pin

sudo -u awx python3.12 -m venv /var/lib/awx/venv/jewel
sudo -u awx bash <<'EOF'
set -euo pipefail
source /var/lib/awx/venv/jewel/bin/activate
cd /opt/jewel
pip install --upgrade pip setuptools wheel
# the requirements layout is the repo's to define — look before you pip:
ls requirements* 2>/dev/null; ls requirements/ 2>/dev/null || true
pip install -r requirements/requirements.txt     # adjust to what ls showed
pip install -e .
pip install uwsgi
EOF
```

Find the manage entrypoint the build just installed — the operator calls it `aap-gateway-manage`; verify and use whatever exists:

```bash
ls /var/lib/awx/venv/jewel/bin/ | grep -i manage    # RECORD the real name; used everywhere below
```

## Settings

Jewel is a Django app from the same family as AWX, and it reads settings the django-ansible-base way. Check the repo (`README`, `docs/`, or the settings module) for the exact mechanism — a settings file path or env vars. What it must be told, whatever the key names:

- postgres: host `localhost`, db `jewel`, user `jewel`, the password from above
- redis: the Lab 4 socket (`unix:///var/run/redis/redis.sock`)
- a `SECRET_KEY` (generate like Lab 6: `head -c 48 /dev/urandom | base64 -w0`)
- allowed hosts / trusted origins: `192.168.56.10`, `ace-control` (with `:8443` for origins)

Put whatever the mechanism is under `/etc/jewel/` (0750, awx-owned), same discipline as `/etc/tower`:

```bash
sudo install -d -o awx -g awx -m 0750 /etc/jewel
```

## Init chain (mirrors the operator's order)

The gateway operator runs, in order: migrate → create the admin. Do the same with the manage entrypoint you found:

```bash
sudo -u awx /var/lib/awx/venv/jewel/bin/aap-gateway-manage migrate --noinput
sudo -u awx /var/lib/awx/venv/jewel/bin/aap-gateway-manage createsuperuser
# username admin — reusing the AWX admin name keeps Lab 16's migrate_service_data simple
```

(The rest of the operator's chain — `authenticators --initialize`, service registration, `generate_service_secret` — is Lab 16's business.)

## Run it: uwsgi on 8080

Envoy's static bootstrap (below) expects jewel's REST control plane on `127.0.0.1:8080` — the same wiring the real gateway pod uses, where envoy and Django are roommates. One unit, uwsgi from the venv:

```bash
sudo tee /etc/jewel/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
http-socket = 127.0.0.1:8080
chdir = /opt/jewel
module = aap_gateway_api.wsgi:application    ; verify the module path in the repo
home = /var/lib/awx/venv/jewel
master = true
processes = 2
harakiri = 120
vacuum = true
EOF

sudo tee /etc/systemd/system/ace-gateway.service >/dev/null <<'EOF'
[Unit]
Description=ACE platform gateway (jewel, uwsgi)
After=network.target postgresql.service redis.service
Wants=postgresql.service redis.service

[Service]
Type=simple
User=awx
Group=awx
ExecStart=/var/lib/awx/venv/jewel/bin/uwsgi /etc/jewel/uwsgi.ini
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo semanage fcontext -a -t bin_t '/var/lib/awx/venv/jewel/bin(/.*)?'   # same 203/EXEC fix as Lab 8
sudo restorecon -Rv /var/lib/awx/venv/jewel/bin
sudo systemctl daemon-reload
sudo systemctl enable --now ace-gateway

curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: JSON pong from jewel, direct — no proxy yet
```

> `http-socket` (plain HTTP), not `socket` (uwsgi protocol) — envoy speaks HTTP to its upstream, unlike Lab 10's nginx→uwsgi wiring.

## envoy from the release binary

Another real tarball moment — envoy ships static binaries per release. Pinned: **v1.38.3**. Note the asset naming quirk: `aarch_64`, with an underscore:

```bash
ENVOY_VERSION=1.38.3
ARCH=$(uname -m); case $ARCH in x86_64) EARCH=x86_64 ;; aarch64) EARCH=aarch_64 ;; esac
curl -fsSL -o /tmp/envoy \
  "https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-${EARCH}"
sudo install -m 0755 /tmp/envoy /usr/local/bin/envoy
envoy --version    # want: 1.38.3
```

## envoy bootstrap — written by hand

The real gateway's envoy config is famously small, because everything interesting arrives at runtime: the bootstrap only says *who the control plane is* and *how to ask it*. Listeners (which ports to open) and clusters (which backends exist) come via **xDS** — envoy polls jewel's REST API every 5 seconds and builds itself from database rows:

```bash
sudo install -d -m 0755 /etc/envoy
sudo tee /etc/envoy/envoy.yaml >/dev/null <<'EOF'
node:
  id: ace-gateway-proxy
  cluster: ace-gateway

dynamic_resources:
  lds_config:
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: 5s
      request_timeout: 5s
    resource_api_version: V3
  cds_config:
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: 5s
      request_timeout: 5s
    resource_api_version: V3

static_resources:
  clusters:
    - name: gateway-control-plane-rest
      type: STATIC
      connect_timeout: 5s
      load_assignment:
        cluster_name: gateway-control-plane-rest
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 8080 }

admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 19000 }
EOF

sudo tee /etc/systemd/system/envoy.service >/dev/null <<'EOF'
[Unit]
Description=Envoy proxy for the ACE gateway
After=network.target ace-gateway.service
Wants=ace-gateway.service

[Service]
Type=simple
User=awx
Group=awx
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now envoy
```

Open the platform door for Lab 16:

```bash
sudo firewall-cmd --permanent --add-port=8443/tcp && sudo firewall-cmd --reload
```

## Verify

```bash
systemctl is-active ace-gateway envoy       # want: active, active

# envoy found its control plane…
curl -s http://127.0.0.1:19000/clusters | grep gateway-control-plane-rest | head -3

# …and is polling for routes that don't exist yet:
curl -s http://127.0.0.1:19000/config_dump | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("configs:", len(d["configs"]))'
```

Envoy up, polling, **no listeners** — an empty proxy waiting for a registry. That emptiness is the lesson: in this architecture, adding a route is an API call, not a config file. Lab 16 makes those calls.

> Milestone note: Labs 1–14 are a complete, working controller. If jewel-from-source turned out to be quicksand above, ship 1–14 and revisit — the [forum thread](https://forum.ansible.com/t/awx-modernization-ansible-jewel/45775) tracks the state of the repo and known patches.

Next: [Service registration](16-service-registration.md)
