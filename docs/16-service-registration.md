# Lab 16 — Service registration

## What you will have at the end

AWX registered as a service behind the gateway: envoy opens `:8443`, one login at the gateway reaches the controller's API, and the Lab 14 job still runs. The platform, assembled.

The object model, the field names, the trust sequence, and the AWX-side settings below are all **verified against the bundle** (`proxy.yml.j2`, `register_services.yml`, `service_token.yml`, `gateway.py.j2`, `post_install_setup.yml`). The bundle drives this with the `ansible.platform` collection's modules over the gateway REST API — we make the same calls with curl. The gateway's browsable API (`http://127.0.0.1:8080/api/gateway/v1/` in a browser) shows every endpoint and its required fields if anything drifts.

All commands on **ace-control**.

## Wait for the gateway, then initialize the local authenticator

```bash
curl -s http://127.0.0.1:8080/api/gateway/v1/ping/ | python3 -m json.tool
# want: {"status":"good", ...} — don't proceed until this answers
```

Now seed the local authenticator (the bundle runs this once, after the services are up — which is exactly here). Without it there's no login backend and every credential is rejected:

```bash
sudo -u gateway aap-gateway-manage authenticators --initialize
# want: "Created default local authenticator"
```

(The `authenticators` subcommand comes from `django-ansible-base`, not jewel's own command set — it won't show up in jewel's `management/commands/` directory, but it's there.)

## Register the registry (the rows envoy is polling for)

Bundle order: HttpPort → ServiceClusters → ServiceNodes → Services. Each row becomes envoy config within 5 seconds. The bundle drives this with the `ansible.platform` collection's modules (over this same REST API); jewel also ships an `aap-gateway-manage register_service --config` command, but it consumes an *older* config format than the current `proxy.yml`, so we go straight to the API.

**The one thing that trips everyone up: `service_type` and `service_cluster` are foreign keys — pass the integer PK, not a name string.** The service types are seeded (`GET $GW/service_types/` → `gateway=1, controller=2, hub=3, eda=4`). Rather than hard-code PKs that could shift, resolve names to IDs as we go. Save this to `register.py` on the box and run it:

```python
import json, subprocess
GW = "http://127.0.0.1:8080/api/gateway/v1"
AUTH = "admin:CHANGE-ME"   # the gateway admin password from Lab 15

def call(method, path, data=None):
    cmd = ["curl", "-s", "-u", AUTH, "-X", method, GW + path, "-H", "Content-Type: application/json"]
    if data is not None:
        cmd += ["-d", json.dumps(data)]
    return json.loads(subprocess.check_output(cmd).decode() or "{}")

def find(path, name):
    r = call("GET", path + "?name=" + name.replace(" ", "%20")).get("results", [])
    return r[0]["id"] if r else None

def ensure(path, name, body):
    existing = find(path, name)
    if existing:
        print(f"  {name}: exists (id={existing})"); return existing
    r = call("POST", path, body)
    print(f"  {name}: created -> {r.get('id', r)}"); return r.get("id")

# 0. service-type PKs, resolved by name
st = {t["name"]: t["id"] for t in call("GET", "/service_types/")["results"]}

# 1. HttpPort — the listener envoy will open
print("http_port:")
hp = ensure("/http_ports/", "API Port",
            {"name": "API Port", "number": 8443, "use_https": True, "is_api_port": True})

# 2. ServiceClusters — named backend pools (service_type is a PK)
print("clusters:")
gw_c  = ensure("/service_clusters/", "gateway",    {"name": "gateway",    "service_type": st["gateway"]})
ctl_c = ensure("/service_clusters/", "controller", {"name": "controller", "service_type": st["controller"]})

# 3. ServiceNodes — endpoints in the pools (service_cluster is a PK; controller = our nginx)
print("nodes:")
ensure("/service_nodes/", "Node gateway - ace-control",
       {"name": "Node gateway - ace-control", "address": "127.0.0.1", "service_cluster": gw_c})
ensure("/service_nodes/", "Node controller - ace-control",
       {"name": "Node controller - ace-control", "address": "192.168.56.10", "service_cluster": ctl_c})

# 4. Services — URL slug -> cluster, with match order.
#    gateway api  = catch-all at order 100, no gateway auth on itself, plain HTTP to uwsgi :8080
#    controller api = order 1, HTTPS to nginx :443, served under /api/controller/
print("services:")
ensure("/services/", "gateway api",
       {"name": "gateway api", "api_slug": "gateway", "http_port": hp, "service_cluster": gw_c,
        "is_service_https": False, "service_path": "/", "service_port": 8080,
        "order": 100, "enable_gateway_auth": False})
ensure("/services/", "controller api",
       {"name": "controller api", "api_slug": "controller", "http_port": hp, "service_cluster": ctl_c,
        "is_service_https": True, "service_path": "/api/controller/", "service_port": 443,
        "order": 1})
```

```bash
read -s -p "gateway admin password: " GW_PW; echo    # then edit AUTH in register.py
python3 register.py
```

If a POST rejects a field, `curl -s -u admin:... -X OPTIONS "$GW/services/" | python3 -m json.tool` lists what that endpoint actually wants, including which fields are FK `"field"` types — the API is the truth, this page is the map. (The controller cluster speaks TLS to nginx; the lab CA is in the system trust from Lab 10, so verification works.)

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

> **If you script this instead of hand-copying:** `generate_service_secret` prints a `colorama` deprecation warning to **STDOUT**, above the token. A naive capture (`... | tr -d '\n'`) will merge the warning text into the secret — and the apostrophe in it breaks the single-quoted `SECRET_KEY` string in `gateway.py`, which surfaces later as a gateway 500 ("no python application found"). Grab only the token line: `... generate_service_secret controller | grep -E '^[A-Za-z0-9_-]{40,}$' | tail -1`.

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

> **Heads-up — this step disables the standalone controller login.** The moment `RESOURCE_SERVER['URL']` is set, AWX's `settings/__init__.py` deliberately forces **JWT-only** authentication (`REST_FRAMEWORK.DEFAULT_AUTHENTICATION_CLASSES` becomes just the gateway JWT consumer) — its comment: *"prevents direct API access to Controller bypassing the platform's authentication."* From now on you log in **at the platform**, not at the controller's own UI on :443. That UI will still render, but every API call it makes returns `401` and the page just sits there — a login that looks like it does nothing. The intended front door is the platform UI (a `@ansible/platform-ui` build fronting the gateway). **Until you build that UI, keep a way in for lab work** by commenting out the `RESOURCE_SERVER` block above: the gateway's JWT trust (`ANSIBLE_BASE_JWT_KEY`) stays, so gateway-fronted access keeps working, and the controller's own session login comes back. The only thing you lose is AWX's reverse user-sync to the gateway, which a single-box lab doesn't need. Re-enable it once a platform UI exists.

**3. Merge AWX's users/orgs/teams up into the platform** — the bundle's post-install step, after trust exists. This one calls the controller *through the gateway* (`https://localhost:8443/api/controller/...`), so it hits the lab-CA-signed front-door cert — and Python's `requests` validates against **certifi's** bundle, not the system trust where Lab 10 installed the lab CA. Point it at the system bundle with `REQUESTS_CA_BUNDLE`:

```bash
sudo -u gateway bash -c 'REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
  aap-gateway-manage migrate_service_data --username admin'
# want: "Controller and Gateway superusers are consistent" and
#       "Service authentication is now enabled." — it calls AWX as the gateway,
#       so AWX must be up and trusting (step 2), or this 401s.
```

> **A `503` here (not `401`) means you're racing the restart from step 2.** The gateway proxies this call to the controller upstream, and for a few seconds after `systemctl restart automation-controller` that upstream is still marked down. Wait until `curl -sk https://localhost:8443/api/controller/v2/ping/` returns `200`, then re-run — it's idempotent.

> **Two SSL traps here, both from the self-call to `localhost:8443`.** Without `REQUESTS_CA_BUNDLE` you get `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` (certifi doesn't know the lab CA). With it, you might still get `Hostname mismatch, certificate is not valid for 'localhost'` — which is why Lab 15's gateway cert carries a `DNS:localhost` SAN. If you built that cert without `localhost`, reissue it (Lab 15) before this step.

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

The controller is behind the gateway. The next two labs bring the other platform services in the same way — each built from source, each joining the same single sign-on.

Next: [Automation Hub](17-hub.md)
