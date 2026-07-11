# Lab 16 — Service registration

## What you will have at the end

AWX registered as a service behind the gateway: envoy opens `:8443`, one login at the gateway reaches the controller's API, and the Lab 14 job still runs. The platform, assembled.

The object model, the field names, the trust sequence, and the AWX-side settings below are all **verified against the bundle** (`proxy.yml.j2`, `register_services.yml`, `service_token.yml`, `gateway.py.j2`, `post_install_setup.yml`). The bundle drives this with the `ansible.platform` collection's modules over the gateway REST API — we make the same calls with curl. The gateway's browsable API (`http://127.0.0.1:8080/api/gateway/v1/` in a browser) shows every endpoint and its required fields if anything drifts.

All commands on **ace-control**.

## Wait for the gateway

```bash
curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: pong — don't proceed until this answers
```

(The local authenticator was initialized in Lab 15's init chain — logins work.)

## Register the registry (the rows envoy is polling for)

Bundle order: HttpPort → ServiceClusters → ServiceNodes → Services. Each row becomes envoy config within 5 seconds of the POST. Names below are the installer's own:

```bash
read -s -p "gateway admin password: " GW_PW; echo
GW="http://127.0.0.1:8080/api/gateway/v1"
J='Content-Type: application/json'

# 1. HttpPort — the listener envoy will open (the bundle's "API Port")
curl -s -u "admin:${GW_PW}" -X POST "$GW/http_ports/" -H "$J" \
  -d '{"name": "API Port", "number": 8443, "use_https": true, "is_api_port": true}' \
  | python3 -m json.tool

# 2. ServiceClusters — named backend pools
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_clusters/" -H "$J" \
  -d '{"name": "gateway", "service_type": "gateway"}' | python3 -m json.tool
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_clusters/" -H "$J" \
  -d '{"name": "controller", "service_type": "controller"}' | python3 -m json.tool

# 3. ServiceNodes — endpoints in the pools (controller = our nginx front door)
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_nodes/" -H "$J" \
  -d '{"name": "Node gateway - ace-control", "address": "127.0.0.1", "service_cluster": "gateway"}' \
  | python3 -m json.tool
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_nodes/" -H "$J" \
  -d '{"name": "Node controller - ace-control", "address": "192.168.56.10", "service_cluster": "controller"}' \
  | python3 -m json.tool

# 4. Services — URL prefix → cluster, with match priority.
#    controller api → https to nginx:443; gateway api = catch-all at order 100, no gateway auth on itself
curl -s -u "admin:${GW_PW}" -X POST "$GW/services/" -H "$J" \
  -d '{"name": "controller api", "api_slug": "controller", "http_port": "API Port",
       "service_cluster": "controller", "is_service_https": true, "service_port": 443,
       "order": 50}' | python3 -m json.tool
curl -s -u "admin:${GW_PW}" -X POST "$GW/services/" -H "$J" \
  -d '{"name": "gateway api", "api_slug": "gateway", "http_port": "API Port",
       "service_cluster": "gateway", "is_service_https": false, "service_path": "/",
       "service_port": 8080, "order": 100, "enable_gateway_auth": false}' | python3 -m json.tool
```

If a POST rejects a field, `curl -s -u admin:... -X OPTIONS "$GW/services/" | python3 -m json.tool` lists what that endpoint actually wants — the API is the truth, this page is the map. (The controller cluster speaks TLS to nginx; the lab CA is in the system trust from Lab 10, so verification works.)

Watch envoy wake up:

```bash
sleep 6
sudo ss -tlnp | grep 8443    # want: envoy now listening
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool
# want: pong — through envoy this time
```

## The trust handshake (this exact order — skipping it is THE classic failure)

Two directions of trust, both bundle-verified, both required **before** `migrate_service_data` — running that first is why the forum is full of 401 loops:

**1. Mint the controller's service secret** (the bundle's `generate_service_secret`; if you ever lose the output, the bundle re-reads it via `aap-gateway-manage shell_plus`):

```bash
sudo -u gateway aap-gateway-manage generate_service_secret controller
# RECORD the output secret
```

**2. Tell AWX to trust the gateway.** This is the bundle's `/etc/tower/conf.d/gateway.py`, near-verbatim:

```bash
sudo -u awx tee /etc/tower/conf.d/gateway.py >/dev/null <<'EOF'
# JWTs: fetch the gateway's public key from this URL and trust its logins
ANSIBLE_BASE_JWT_KEY = 'https://192.168.56.10:8443'
ANSIBLE_BASE_JWT_REDIRECT_TYPE = "awx"
ANSIBLE_BASE_JWT_VALIDATE_CERT = True
ANSIBLE_BASE_MANAGED_ROLE_REGISTRY = {'platform_auditor': {'name': 'Platform Auditor', 'shortname': 'sys_auditor'}}

# make AWX also answer at /api/controller/v2/ — the slug path the gateway routes to
OPTIONAL_API_URLPATTERN_PREFIX = "controller"

ENABLE_SERVICE_BACKED_SSO = False

# service-to-service: how AWX calls the gateway back, as itself
RESOURCE_SERVER = {
    'URL': 'https://192.168.56.10:8443',
    'SECRET_KEY': 'PASTE-THE-GENERATED-SECRET',
    'VALIDATE_HTTPS': True,
}

REMOTE_HOST_HEADERS = ['HTTP_X_FORWARDED_FOR', 'REMOTE_ADDR', 'REMOTE_HOST']
EOF
sudo vim /etc/tower/conf.d/gateway.py    # paste the real secret
sudo systemctl restart automation-controller
```

(`OPTIONAL_API_URLPATTERN_PREFIX` is the quiet one that matters: without it, the gateway proxies `/api/controller/v2/...` to an AWX that only serves `/api/v2/` — 404s everywhere. The JWT key is a URL, not a key: AWX fetches the gateway's public key at runtime; rotate at the gateway and every component follows.)

**3. Merge AWX's users/orgs/teams up into the platform** — the bundle's post-install step, after trust exists:

```bash
sudo -u gateway aap-gateway-manage migrate_service_data --username admin
# it calls AWX as the gateway — AWX must be up and trusting, or this 401s
```

## Verify — one login, whole platform

```bash
# the gateway answers on the platform port
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool

# the controller answers THROUGH the gateway, on the slug path
curl -sk -u "admin:${GW_PW}" \
  https://192.168.56.10:8443/api/controller/v2/ping/ | python3 -m json.tool
# want: AWX's ping JSON — via envoy → (gateway auth over gRPC) → nginx → uwsgi

# and the Lab 14 job still runs through the platform door:
curl -sk -u "admin:${GW_PW}" -X POST \
  https://192.168.56.10:8443/api/controller/v2/job_templates/<JT_ID>/launch/ \
  | python3 -c 'import json,sys; print("job:", json.load(sys.stdin)["job"])'
```

That second curl is the whole platform in one line: envoy took the request on the platform port, checked it with jewel over the gRPC control plane, jewel attached a JWT, the route sent it to nginx, nginx to uwsgi, and AWX's jwt_consumer accepted the gateway's word for who you are. Every hop hand-built.

> The unified platform UI is a separate build (the `ansible-ui` tree from Lab 9 has a platform target) — a future chapter. The API-level platform above is the real milestone.

Back to the [README](../README.md) — you built an automation platform by hand.
