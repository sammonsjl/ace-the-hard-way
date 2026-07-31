# Lab 17 — The platform UI (and the 443 pivot)

## What you will have at the end

The **unified platform UI** — `@ansible/platform-ui`, one login, the Ansible console — served by
the gateway on **port 443**. This is the pivot the whole tutorial has been building toward: the
gateway becomes the front door, and the controller steps back behind it.

```
browser ── https://192.168.56.10  (443)
            envoy ──┬── /                  → platform UI SPA    (Ansible console)
                    ├── /api/gateway/      → gateway uwsgi
                    └── /api/controller/   → controller nginx :8043

                    (/api/galaxy/ and /api/eda/ appear as Labs 18–19 register them)
```

> **One service is enough.** The console's navigation is not hardcoded — it comes from `GET /api/`,
> the gateway's **service registry**. With only the controller registered you get a working platform
> UI showing **Automation Execution**, and nothing else. Hub and EDA are not prerequisites; each one
> you register later simply appears in the nav. That's why this lab now comes before them: the pivot
> to 443 is a controller-and-gateway affair, and doing it first means Labs 18–19 are written against
> the final layout instead of being rewritten by it.

> **Two UIs, and why this one needs the gateway.** [Lab 9](09-awx-ui.md) built the *standalone*
> AWX UI (`frontend/awx` + `AWX_SERVER`) — single-service, no gateway, AWX-branded. This lab
> builds the *platform* UI (`platform/` + `PLATFORM_SERVER`), which is a different app: its login
> is `/api/gateway/v1/session/` and its navigation comes from `GET /api/` (the gateway's service
> registry). Point it at a bare controller and every one of those calls 404s — it genuinely
> cannot run without the gateway. That's not a limitation to work around; it *is* the platform.

All commands on **ace-control**. Assumes Labs 15–16 (the gateway, with the controller registered
behind it on :8443).

## Why 443

The design the whole platform layer assumes: **envoy on 443** as the single public front door, the
gateway's own uwsgi behind it on 8443, and the controller, hub, and EDA each on 443 **on their own
hosts**. We've been bringing the gateway up on 8443 to keep it side-by-side with the controller
(which took 443 back in Lab 10) — easy to test both. Now we commit: give envoy 443, and move the
controller to an internal port behind it. (On one box they can't all be 443, so the controller lands
on 8043 — and Labs 18–19 will put hub on 8444 and EDA on 8445 for the same reason. The single-box
tax on a design meant for separate hosts.)

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

Stage it where the gateway serves the UI — the `STATIC_ROOT` from Lab 15. The directory is `root:nginx` from
Lab 15's `collectstatic`, so copy as root:

```bash
sudo cp -a /opt/ansible-ui/platform/dist/. /var/lib/ansible-automation-platform/platform/ui/
sudo chown -R root:nginx /var/lib/ansible-automation-platform/platform/ui
sudo -u awx ls /var/lib/ansible-automation-platform/platform/ui/index.html   # want: it exists
```

## Serve the SPA + gateway API from one nginx

The gateway's catch-all "gateway api" service currently sends `/` straight to the gateway's uwsgi
(which returns the API, not a UI). Put a small nginx in front of the uwsgi that serves the SPA at
`/` and proxies the gateway's own API paths back to uwsgi. (This is the nginx layer we deliberately
simplified away in Lab 15 — now there's a UI to serve, it earns its place.)

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
envoy's catch-all serves the SPA.

The rest of this lab edits registry rows the same way, so set these once in the shell you're
working in — every block below reuses them:

```bash
GW=http://127.0.0.1:8080/api/gateway/v1
read -s -p "gateway admin password: " GW_PW; echo
```

```bash
SVC=$(curl -s -u "admin:${GW_PW}" "$GW/services/?name=gateway%20api" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

curl -s -u "admin:${GW_PW}" -X PATCH "$GW/services/$SVC/" \
  -H 'Content-Type: application/json' \
  -d '{"service_port": 8446, "is_service_https": false}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], "→ port", d["service_port"], "https:", d["is_service_https"])'
# want: gateway api → port 8446 https: False
```

Give envoy its five-second xDS poll, then confirm the catch-all serves the SPA instead of the API:

```bash
sleep 6
curl -sk https://192.168.56.10:8443/ -o /dev/null -w 'root: %{http_code} %{content_type}\n'
# want: root: 200 text/html   — the SPA. `application/json` means envoy is still
#       sending / to the gateway API; give the xDS poll another few seconds.
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
```bash
SVC=$(curl -s -u "admin:${GW_PW}" "$GW/services/?name=controller%20api" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

curl -s -u "admin:${GW_PW}" -X PATCH "$GW/services/$SVC/" \
  -H 'Content-Type: application/json' -d '{"service_port": 8043}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print(d["name"], "→ port", d["service_port"])'
# want: controller api → port 8043
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

```bash
HP=$(curl -s -u "admin:${GW_PW}" "$GW/http_ports/?name=API%20Port" \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

curl -s -u "admin:${GW_PW}" -X PATCH "$GW/http_ports/$HP/" \
  -H 'Content-Type: application/json' -d '{"number": 443}' \
  | python3 -c 'import json,sys; d=json.load(sys.stdin); print("http port →", d["number"])'
# want: http port → 443
```

```bash
sleep 8
sudo ss -tlnp | grep -q ':443 ' && echo "envoy on 443" || echo "not yet — check journalctl -u automation-gateway-proxy"
```

## Re-point every URL from :8443 to :443

Labs 15–16 wrote the platform URL as `https://192.168.56.10:8443` in two config files. The front door
is 443 now (the default HTTPS port, no suffix), so rewrite both — miss one and JWT validation or CSRF
breaks on that component:

```bash
sudo sed -i 's#https://192.168.56.10:8443#https://192.168.56.10#g' \
  /etc/ansible-automation-platform/gateway/settings.py \
  /etc/tower/conf.d/gateway.py

# the gateway's own proxy-url setting (DB-backed; PUT, not PATCH)
curl -s -u "admin:${GW_PW}" -X PUT http://127.0.0.1:8080/api/gateway/v1/settings/all/ \
  -H 'Content-Type: application/json' -d '{"gateway_proxy_url": "https://192.168.56.10"}' >/dev/null

sudo systemctl restart automation-gateway automation-controller
```

> The controller's `ANSIBLE_BASE_JWT_KEY` is the URL where it fetches the gateway's JWT **public
> key** at runtime. If it still says `:8443` after the pivot, that fetch fails and every proxied call
> comes back `403` — the tell that one of these URLs got missed.
>
> Labs 18–19 write hub's and EDA's equivalents (`ANSIBLE_BASE_JWT_KEY`, `CONTENT_ORIGIN`,
> `WEBSOCKET_BASE_URL`) directly as `https://192.168.56.10`, because by then the pivot has already
> happened — nothing to rewrite.

## Verify — the platform on 443

```bash
curl -sk https://192.168.56.10/ | grep -oE '/assets/index-[^"]+\.js' | head -1   # the SPA's entry bundle
curl -sk https://192.168.56.10/platform-logo.svg -o /dev/null -w '%{http_code}\n'  # Ansible logo: 200

# one login, reaching the controller — through 443:
curl -sk -u "admin:${GW_PW}" https://192.168.56.10/api/controller/v2/ping/  -o /dev/null -w 'controller: %{http_code}\n'
```

Then the real test — a browser to **`https://192.168.56.10`** (accept the lab-CA warning):

- the Ansible-branded platform login page loads;
- log in as the gateway admin — the console shows **Automation Execution (Controller)**. That is
  the whole navigation for now, and it's correct: the nav is built from the gateway's service
  registry, and the controller is the only service in it. **Automation Content (Hub)** and
  **Automation Decisions (EDA)** appear as Labs 18–19 register them — no rebuild of the UI, just a
  refresh;
- launch the Demo Job Template from the UI — it runs on ace-exec, exactly as in Lab 14, but now
  driven from the platform console.

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

curl -sk -u "admin:${GW_PW}" https://192.168.56.10/api/controller/v2/config/ \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["license_info"]["compliant"])'   # want: True
```

Refresh the console and the banner is gone. (This is a source patch like Lab 5's `devonly` removal —
it doesn't survive a `git pull` of `/opt/awx`, so re-apply it if you rebuild.)

> **Posture note (optional).** With the platform UI as the real front door, you can restore the
> full lockdown from [Lab 16](16-service-registration.md) — un-comment the `RESOURCE_SERVER`
> block in `/etc/tower/conf.d/gateway.py` — so the controller accepts *only* gateway-issued JWTs and
> there's no direct login bypassing the platform. Leave it commented if you'd rather keep the
> standalone :8043 UI usable for debugging.

Next: [Automation Hub](18-hub.md)
