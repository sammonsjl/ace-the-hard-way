# Lab 19 — The platform UI (and the real-AAP 443 pivot)

## What you will have at the end

The **unified platform UI** — `@ansible/platform-ui`, Ansible-branded, one login, Controller +
Hub + EDA in a single navigation — served by the gateway on **port 443**, exactly where a real
AAP install puts it. This is the pivot the whole tutorial has been building toward: the gateway
becomes the front door, and the controller steps back behind it.

```
browser ── https://192.168.56.10  (443)
            envoy ──┬── /            → platform UI SPA          (Ansible console)
                    ├── /api/gateway/ → gateway uwsgi
                    ├── /api/controller/ → controller nginx :8043
                    ├── /api/galaxy/     → hub nginx :8444
                    └── /api/eda/        → eda nginx :8445
```

> **Two UIs, and why this one needs the gateway.** [Lab 9](09-awx-ui.md) built the *standalone*
> AWX UI (`frontend/awx` + `AWX_SERVER`) — single-service, no gateway, AWX-branded. This lab
> builds the *platform* UI (`platform/` + `PLATFORM_SERVER`), which is a different app: its login
> is `/api/gateway/v1/session/` and its navigation comes from `GET /api/` (the gateway's service
> registry). Point it at a bare controller and every one of those calls 404s — it genuinely
> cannot run without the gateway. That's not a limitation to work around; it *is* the platform.

All commands on **ace-control**. Assumes Labs 15–18 (gateway + hub + EDA, all on :8443).

## Why 443, and what the bundle says

In a real AAP install the public front door is **envoy on 443** (`_automationgatewayproxy_https_port: 443`
in the installer's `collection_global_vars.yml`); the gateway's own uwsgi sits behind it on 8443, and
the controller, hub, and EDA each run nginx on 443 **on their own hosts**. We've been bringing the
gateway up on 8443 to keep it side-by-side with the controller (which took 443 back in Lab 10) — easy
to test both. Now we do what the installer does: give envoy 443, and move the controller to an internal
port behind it. (On one box the three services can't all be 443, so the controller lands on 8043, hub
stays 8444, EDA 8445 — the single-box tax on a design meant for separate hosts.)

## Build the platform UI

Same `ansible-ui` checkout as Lab 9 — a *different workspace*. `PLATFORM_SERVER` is the gateway's
public URL (443, so no port suffix); the built SPA makes same-origin calls, so this value mostly
feeds the dev server and websocket base:

```bash
sudo -u awx bash <<'EOF'
set -euo pipefail
cd /opt/ansible-ui/platform
export PLATFORM_SERVER="https://192.168.56.10"
export NODE_OPTIONS="--max-old-space-size=6144"      # the platform build is heavier than frontend/awx
npm run build                                        # -> platform/dist
git -C /opt/ansible-ui rev-parse --short HEAD        # RECORD — same commit as Lab 9's build
EOF
```

Stage it where the gateway serves the UI (the bundle's path). The directory is `root:nginx` from
Lab 15's `collectstatic`, so copy as root:

```bash
sudo cp -a /opt/ansible-ui/platform/dist/. /var/lib/ansible-automation-platform/platform/ui/
sudo chown -R root:nginx /var/lib/ansible-automation-platform/platform/ui
sudo -u awx ls /var/lib/ansible-automation-platform/platform/ui/index.html   # want: it exists
```

## Serve the SPA + gateway API from one nginx

The gateway's catch-all "gateway api" service currently sends `/` straight to the gateway's uwsgi
(which returns the API, not a UI). Put a small nginx in front of the uwsgi that serves the SPA at
`/` and proxies the gateway's own API paths back to uwsgi. (In the bundle this *is* the gateway's
nginx; we add it now because we simplified it away in Lab 15.)

```bash
sudo tee /etc/nginx/conf.d/automation-gateway-ui.nginx.conf >/dev/null <<'EOF'
server {
    listen 8446;
    server_name _;
    root /var/lib/ansible-automation-platform/platform/ui;
    client_max_body_size 100m;

    location /static/ { alias /var/lib/ansible-automation-platform/platform/ui/static/; }

    location /api/ {          # only /api/gateway/... reaches here (other /api/* are separate envoy routes)
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:8080;
        proxy_read_timeout 120s;
    }
    location /o/ {            # gateway OAuth
        proxy_set_header Host $http_host;
        proxy_set_header X-Forwarded-Proto https;
        proxy_pass http://127.0.0.1:8080;
    }
    location / { try_files $uri /index.html; }   # SPA fallback
}
EOF

sudo semanage port -a -t http_port_t -p tcp 8446   # nginx may only bind labeled ports (Lab 17)
sudo firewall-cmd --permanent --add-port=8446/tcp && sudo firewall-cmd --reload
sudo nginx -t && sudo systemctl reload nginx
```

Re-point the gateway's "gateway api" service from the uwsgi port (8080) to this nginx (8446), so
envoy's catch-all serves the SPA. Reuse Lab 16's `call`/`find` helpers:

```python
svc = find("/services/", "gateway api")
call("PATCH", f"/services/{svc}/", {"service_port": 8446, "is_service_https": False})
```

## The 443 pivot

Now the real move. Order matters — free 443 on the controller **before** envoy tries to take it.

**1. Controller nginx 443 → 8043** (and tell the gateway where the controller went):

```bash
sudo sed -i 's/listen 443 ssl http2 default_server;/listen 8043 ssl http2 default_server;/' \
  /etc/nginx/conf.d/automation-controller.nginx.conf
sudo semanage port -a -t http_port_t -p tcp 8043
sudo firewall-cmd --permanent --add-port=8043/tcp && sudo firewall-cmd --reload
sudo nginx -t && sudo systemctl reload nginx
```
```python
svc = find("/services/", "controller api")
call("PATCH", f"/services/{svc}/", {"service_port": 8043})
```

**2. Let envoy bind 443.** It runs as the non-root `gateway` user, so grant it the one capability
for privileged ports (a systemd drop-in — cleaner than `setcap` on a binary that gets replaced):

```bash
sudo mkdir -p /etc/systemd/system/automation-gateway-proxy.service.d
sudo tee /etc/systemd/system/automation-gateway-proxy.service.d/bind443.conf >/dev/null <<'EOF'
[Service]
AmbientCapabilities=CAP_NET_BIND_SERVICE
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
EOF
sudo systemctl daemon-reload
sudo systemctl restart automation-gateway-proxy
```

**3. Move the envoy listener 8443 → 443** by changing the gateway's `HttpPort` number. Envoy
picks up the new listener via xDS within a few seconds:

```python
hp = find("/http_ports/", "API Port")
call("PATCH", f"/http_ports/{hp}/", {"number": 443})
```

```bash
sleep 8
sudo ss -tlnp | grep -q ':443 ' && echo "envoy on 443" || echo "not yet — check journalctl -u automation-gateway-proxy"
```

## Re-point every URL from :8443 to :443

Labs 15–18 wrote the platform URL as `https://192.168.56.10:8443` in five places. The front door is
443 now (the default HTTPS port, no suffix), so rewrite them all — miss one and JWT validation or CSRF
breaks on that component:

```bash
sudo sed -i 's#https://192.168.56.10:8443#https://192.168.56.10#g' \
  /etc/ansible-automation-platform/gateway/settings.py \
  /etc/tower/conf.d/gateway.py \
  /etc/pulp/settings.py
sudo sed -i 's#https://192.168.56.10:8443#https://192.168.56.10#g; s#wss://192.168.56.10:8443#wss://192.168.56.10#g' \
  /etc/eda/settings.yaml

# the gateway's own proxy-url setting (DB-backed; PUT, not PATCH)
curl -s -u admin:CHANGE-ME -X PUT http://127.0.0.1:8080/api/gateway/v1/settings/all/ \
  -H 'Content-Type: application/json' -d '{"gateway_proxy_url": "https://192.168.56.10"}' >/dev/null

sudo systemctl restart automation-gateway automation-controller \
  pulpcore-api pulpcore-content pulpcore-worker@1 pulpcore-worker@2 \
  automation-eda-api automation-eda-default-worker
```

> The controller's `ANSIBLE_BASE_JWT_KEY` (and hub's / EDA's) is the URL where each service fetches
> the gateway's JWT **public key** at runtime. If it still says `:8443` after the pivot, that fetch
> fails and every proxied call comes back `403` — the tell that one of these URLs got missed.

## Verify — the platform on 443, like real AAP

```bash
curl -sk https://192.168.56.10/ | grep -o 'PlatformMain-[^"]*\.js' | head -1   # the SPA is the platform build
curl -sk https://192.168.56.10/platform-logo.svg -o /dev/null -w '%{http_code}\n'  # Ansible logo: 200

# one login, whole platform — all through 443:
curl -sk -u admin:CHANGE-ME https://192.168.56.10/api/controller/v2/ping/  -o /dev/null -w 'controller: %{http_code}\n'
curl -skL -u admin:CHANGE-ME https://192.168.56.10/api/galaxy/_ui/v1/me/    -o /dev/null -w 'hub:        %{http_code}\n'
curl -sk -u admin:CHANGE-ME https://192.168.56.10/api/eda/v1/users/me/      -o /dev/null -w 'eda:        %{http_code}\n'
```

Then the real test — a browser to **`https://192.168.56.10`** (accept the lab-CA warning):

- the Ansible-branded platform login page loads;
- log in as the gateway admin — the console shows **Automation Execution (Controller)**,
  **Automation Content (Hub)**, and **Automation Decisions (EDA)** in one navigation;
- launch the Demo Job Template from the UI — it runs on ace-exec, exactly as in Lab 14, but now
  driven from the unified console.

The standalone AWX UI from Lab 9 is still there if you want it, on its new internal port
`https://192.168.56.10:8043` — the same UI, now behind the gateway instead of in front of it.

## Silence the false "subscription out of compliance" banner

The platform console shows a red banner — *"Your subscription is out of compliance"* — and it's
spurious on a from-source build. `PlatformApp.tsx` renders it whenever
`!awxConfig.license_info.compliant`, reading the controller's `/api/controller/v2/config/`. But a
source AWX (`detect_server_product_name() == 'AWX'`) uses `OpenLicense`, whose `validate()` returns
**no `compliant` field at all** — and the UI reads missing-as-non-compliant. An open license is
unlimited; there's nothing to be out of compliance *with*. Make it say so:

```bash
# in /opt/awx/awx/main/utils/licensing.py, OpenLicense.validate() returns a dict — add one key:
#     valid_key=True,
#     compliant=True,      # <-- add this line
sudo -u awx sed -i "s/^            valid_key=True,$/            valid_key=True,\n            compliant=True,/" \
  /opt/awx/awx/main/utils/licensing.py
sudo systemctl restart automation-controller

curl -sk -u admin:CHANGE-ME https://192.168.56.10/api/controller/v2/config/ \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["license_info"]["compliant"])'   # want: True
```

Refresh the console and the banner is gone. (This is a source patch like Lab 5's `devonly` removal —
it doesn't survive a `git pull` of `/opt/awx`, so re-apply it if you rebuild.)

> **Posture note (optional).** With the platform UI as the real front door, you can restore the
> "proper" AAP lockdown from [Lab 16](16-service-registration.md) — un-comment the `RESOURCE_SERVER`
> block in `/etc/tower/conf.d/gateway.py` — so the controller accepts *only* gateway-issued JWTs and
> there's no direct login bypassing the platform. Leave it commented if you'd rather keep the
> standalone :8043 UI usable for debugging.

Back to the [README](../README.md) — you built an automation platform, every service and its
console, by hand.
