# Lab 16 — Service registration

## What you will have at the end

AWX registered as a service behind the gateway: envoy opens `:8443`, one login at the gateway reaches the controller's API, and the Lab 14 job still runs. The platform, assembled.

> Same dragons as Lab 15: the *sequence* below is the operator's exact init chain (known-good), but endpoint field names and manage-command flags live in a moving repo. The gateway's browsable API (`/api/gateway/v1/` in a browser) is your source of truth for every POST body.

All commands on **ace-control**. `aap-gateway-manage` = whatever entrypoint name you recorded in Lab 15.

## Wait for the gateway

```bash
curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: pong — don't proceed until this answers
```

## The local authenticator

The operator runs this before anything can log in — it creates the local username/password authenticator:

```bash
sudo -u awx /var/lib/awx/venv/jewel/bin/aap-gateway-manage authenticators --initialize
```

## Register the registry (the rows envoy is polling for)

Five object types, created bottom-up — each becomes envoy config within 5 seconds of the POST. The operator authenticates with a minted OAuth2 token; plain admin basic auth works the same for a lab. Explore `/api/gateway/v1/` first — the browsable API shows every endpoint and its fields:

```bash
read -s -p "gateway admin password: " GW_PW; echo
GW="http://127.0.0.1:8080/api/gateway/v1"
J='Content-Type: application/json'

# 1. HttpPort — the listener envoy will open
curl -s -u "admin:${GW_PW}" -X POST "$GW/http_ports/" -H "$J" \
  -d '{"name": "port-8443", "number": 8443}' | python3 -m json.tool

# 2. ServiceClusters — named backend pools
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_clusters/" -H "$J" \
  -d '{"name": "controller", "service_type": "controller"}' | python3 -m json.tool
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_clusters/" -H "$J" \
  -d '{"name": "gateway", "service_type": "gateway"}' | python3 -m json.tool

# 3. ServiceNodes — endpoints in the pools (controller = our nginx front door)
curl -s -u "admin:${GW_PW}" -X POST "$GW/service_nodes/" -H "$J" \
  -d '{"name": "ace-control", "address": "192.168.56.10", "service_cluster": <CONTROLLER_CLUSTER_ID>}' | python3 -m json.tool

# 4. Services — URL prefix → cluster, with match priority
#    controller at order 1; the gateway itself is the catch-all at order 100
curl -s -u "admin:${GW_PW}" -X POST "$GW/services/" -H "$J" \
  -d '{"name": "controller", "api_slug": "controller", "http_port": <PORT_ID>,
       "service_cluster": <CONTROLLER_CLUSTER_ID>, "is_service_https": true,
       "service_port": 443, "order": 1}' | python3 -m json.tool
curl -s -u "admin:${GW_PW}" -X POST "$GW/services/" -H "$J" \
  -d '{"name": "gateway", "api_slug": "gateway", "http_port": <PORT_ID>,
       "service_cluster": <GATEWAY_CLUSTER_ID>, "service_path": "/",
       "service_port": 8080, "order": 100}' | python3 -m json.tool
```

Substitute the ids from each response into the next call. Field names drifted? The browsable API's OPTIONS output on each endpoint lists what's required — trust it over this page.

Watch envoy wake up:

```bash
sleep 6
sudo ss -tlnp | grep 8443                          # want: envoy now listening
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool
# want: pong — through envoy this time
```

(If the listener is plain HTTP instead of TLS on your jewel checkout, the HttpPort object controls TLS and cert wiring — check its OPTIONS. Wiring the Lab 10 CA cert in is the fidelity move; note what you find.)

## The trust handshake (this exact order — skipping it is THE classic failure)

The forum is full of 401 loops from people who registered services but skipped the service secret. Direction 1 (gateway → AWX): a JWT attached to each proxied request. Direction 2 (AWX → gateway): a shared service secret. Both must exist before `migrate_service_data`:

```bash
# 1. mint the controller's service secret
sudo -u awx /var/lib/awx/venv/jewel/bin/aap-gateway-manage generate_service_secret controller
# RECORD the output secret
```

Tell AWX to trust the gateway — a new conf.d fragment (Lab 6 pattern):

```bash
sudo -u awx tee /etc/tower/conf.d/gateway.py >/dev/null <<'EOF'
# JWTs: fetch the gateway's public key from this URL and trust its logins
ANSIBLE_BASE_JWT_KEY = 'https://192.168.56.10:8443'

# service-to-service: how AWX calls the gateway back, as itself
RESOURCE_SERVER = {
    'URL': 'https://192.168.56.10:8443',
    'SECRET_KEY': 'PASTE-THE-GENERATED-SECRET',
}
EOF
sudo vim /etc/tower/conf.d/gateway.py    # paste the real secret
sudo systemctl restart automation-controller
```

(The JWT key is a URL, not a key — AWX fetches the gateway's public key at runtime. Rotate at the gateway; every component follows. Our lab CA is in the system trust from Lab 10, so the https fetch verifies.)

Then merge AWX's users/orgs/teams up into the platform — the step that 401s if you rushed:

```bash
sudo -u awx /var/lib/awx/venv/jewel/bin/aap-gateway-manage migrate_service_data --username=admin
# prompts/flags may vary; it retries against AWX, so AWX must be up and trusting
```

## Verify — one login, whole platform

```bash
# the gateway answers on the platform port
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool

# the controller answers THROUGH the gateway, on the slug path
curl -sk -u "admin:${GW_PW}" \
  https://192.168.56.10:8443/api/controller/v2/ping/ | python3 -m json.tool
# want: the same ping JSON nginx serves on :443 — via envoy → nginx → uwsgi

# and the Lab 14 job still runs through the platform door:
curl -sk -u "admin:${GW_PW}" -X POST \
  https://192.168.56.10:8443/api/controller/v2/job_templates/<JT_ID>/launch/ \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["job"])' 2>/dev/null \
  || echo "field names drift — launch from the API browser at /api/controller/v2/"
```

That second curl is the whole platform in one line: envoy took the request on the platform port, jewel authenticated it and attached a JWT, the route sent it to nginx, nginx to uwsgi, and AWX's jwt_consumer accepted the gateway's word for who you are. Every hop hand-built.

> The unified platform UI is a separate build (the `ansible-ui` tree from Lab 9 has a platform target) — a future chapter. The API-level platform above is the real milestone.

Back to the [README](../README.md) — you built an automation platform by hand.
