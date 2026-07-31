# Lab 16 — Service registration

## What you will have at the end

AWX registered as a service behind the gateway: envoy opens `:443`, one login at the gateway reaches the controller's API, and the Lab 17 job still runs. The platform, assembled.

Everything here happens over the gateway's REST API. Automation would drive it with the `ansible.platform` collection's modules; we make the same calls with curl, so you can see each object as it's created. The gateway's browsable API (`https://127.0.0.1:8443/api/gateway/v1/` in a browser) shows every endpoint and its required fields if anything drifts.

All commands on **ace-control**.

## Wait for the gateway

```bash
curl -sk https://127.0.0.1:8443/api/gateway/v1/ping/ | python3 -m json.tool
# want: {"status":"good", ...} — don't proceed until this answers
```

## Register the registry (the rows envoy is polling for)

Create them in this order — HttpPort → ServiceClusters → ServiceNodes → Services — because each one references the last. Every row becomes envoy config within 5 seconds. jewel also ships an `aap-gateway-manage register_service --config` command, but it consumes an *older* config format than the current `proxy.yml`, so we go straight to the API.

**The one thing that trips everyone up: `service_type` and `service_cluster` are foreign keys — pass the integer PK, not a name string.** The service types are seeded (`GET $GW/service_types/` → `gateway=1, controller=2, hub=3, eda=4`). Rather than hard-code PKs that could shift, resolve names to IDs as we go. Save this to `register.py` on the box and run it:

```python
import json, subprocess
GW = "https://127.0.0.1:8443/api/gateway/v1"
AUTH = "admin:CHANGE-ME"   # the gateway admin password from Lab 6

def call(method, path, data=None):
    cmd = ["curl", "-sk", "-u", AUTH, "-X", method, GW + path, "-H", "Content-Type: application/json"]
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
            {"name": "API Port", "number": 443, "use_https": True, "is_api_port": True})

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
#    gateway api  = catch-all at order 100, no gateway auth on itself, HTTPS to its own nginx :8443
#    controller api = order 1, HTTPS to nginx :8043, served under /api/controller/
print("services:")
ensure("/services/", "gateway api",
       {"name": "gateway api", "api_slug": "gateway", "http_port": hp, "service_cluster": gw_c,
        "is_service_https": True, "service_path": "/", "service_port": 8443,
        "order": 100, "enable_gateway_auth": False})
ensure("/services/", "controller api",
       {"name": "controller api", "api_slug": "controller", "http_port": hp, "service_cluster": ctl_c,
        "is_service_https": True, "service_path": "/api/controller/", "service_port": 8043,
        "order": 1})
```

```bash
read -s -p "gateway admin password: " GW_PW; echo    # then edit AUTH in register.py
python3 register.py
```

If a POST rejects a field, `curl -s -u admin:... -X OPTIONS "$GW/services/" | python3 -m json.tool` lists what that endpoint actually wants, including which fields are FK `"field"` types — the API is the truth, this page is the map. (The controller cluster speaks TLS to nginx; Lab 3's CA is in the system trust, so verification works.)

Watch envoy wake up:

```bash
sleep 6
sudo ss -tlnp | grep ':443 '   # want: envoy now listening on 443
curl -sk https://192.168.56.10/api/gateway/v1/ping/ | python3 -m json.tool
# want: pong — through envoy this time
```

## The trust handshake (this exact order — skipping it is THE classic failure)

Two directions of trust, both required **before** `migrate_service_data` — running that first is why the forum is full of 401 loops:

**1. Mint the controller's service secret** (lose the output and you can re-read it via `aap-gateway-manage shell_plus`):

```bash
sudo -u gateway aap-gateway-manage generate_service_secret controller
# RECORD the output secret
```

> **If you script this instead of hand-copying:** `generate_service_secret` prints a `colorama` deprecation warning to **STDOUT**, above the token. A naive capture (`... | tr -d '\n'`) will merge the warning text into the secret — and the apostrophe in it breaks the single-quoted `SECRET_KEY` string in `gateway.py`, which surfaces later as a gateway 500 ("no python application found"). Grab only the token line: `... generate_service_secret controller | grep -E '^[A-Za-z0-9_-]{40,}$' | tail -1`.

**2. Tell AWX to trust the gateway.** A new settings fragment, `/etc/tower/conf.d/gateway.py`:

```bash
sudo tee /etc/tower/conf.d/gateway.py >/dev/null <<'EOF'
# JWTs: fetch the gateway's public key from this URL and trust its logins
ANSIBLE_BASE_JWT_KEY = 'https://192.168.56.10'
ANSIBLE_BASE_JWT_REDIRECT_TYPE = "awx"
ANSIBLE_BASE_JWT_VALIDATE_CERT = True
ANSIBLE_BASE_MANAGED_ROLE_REGISTRY = {'platform_auditor': {'name': 'Platform Auditor', 'shortname': 'sys_auditor'}}

# make AWX also answer at /api/controller/v2/ — the slug path the gateway routes to
OPTIONAL_API_URLPATTERN_PREFIX = "controller"

ENABLE_SERVICE_BACKED_SSO = False

# service-to-service: how AWX calls the gateway back, as itself
RESOURCE_SERVER = {
    'URL': 'https://192.168.56.10',
    'SECRET_KEY': 'PASTE-THE-GENERATED-SECRET',
    'VALIDATE_HTTPS': True,
}

REMOTE_HOST_HEADERS = ['HTTP_X_FORWARDED_FOR', 'REMOTE_ADDR', 'REMOTE_HOST']
EOF
sudo vim /etc/tower/conf.d/gateway.py    # paste the real secret
sudo systemctl restart automation-controller
```

(`OPTIONAL_API_URLPATTERN_PREFIX` is the quiet one that matters: without it, the gateway proxies `/api/controller/v2/...` to an AWX that only serves `/api/v2/` — 404s everywhere. The JWT key is a URL, not a key: AWX fetches the gateway's public key at runtime; rotate at the gateway and every component follows.)

> **Heads-up — this step closes the controller's own login, on purpose.** The moment
> `RESOURCE_SERVER['URL']` is set, AWX's `settings/__init__.py` deliberately forces **JWT-only**
> authentication — `REST_FRAMEWORK.DEFAULT_AUTHENTICATION_CLASSES` becomes just the gateway JWT
> consumer, with the comment *"prevents direct API access to Controller bypassing the platform's
> authentication."*
>
> So from here on, `https://192.168.56.10:8043/api/v2/` still renders the browsable API but every
> call returns `401`. That is correct behaviour, not a regression: there is exactly one front door
> now, and it is the platform. You already built the console that uses it
> ([Lab 7](07-platform-ui.md)), so nothing is lost — this is the step that makes single sign-on
> mean something, rather than being one login option among two.
>
> If you need the direct route back temporarily while debugging, comment out the `RESOURCE_SERVER`
> block and restart: `ANSIBLE_BASE_JWT_KEY` stays, so gateway-fronted access keeps working and the
> controller's session login returns. The only thing you give up is AWX's reverse user-sync to the
> gateway.

**3. Merge AWX's users/orgs/teams up into the platform** — the last step, and only once trust exists in both directions. This one calls the controller *through the gateway* (`https://localhost/api/controller/...`), so it hits the CA-signed front-door cert — and Python's `requests` validates against **certifi's** bundle, not the system trust where Lab 3 installed our CA. Point it at the system bundle with `REQUESTS_CA_BUNDLE`:

```bash
sudo -u gateway bash -c 'REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
  aap-gateway-manage migrate_service_data --username admin'
# want: "Controller and Gateway superusers are consistent" and
#       "Service authentication is now enabled." — it calls AWX as the gateway,
#       so AWX must be up and trusting (step 2), or this 401s.
```

> **A `503` here (not `401`) means you're racing the restart from step 2.** The gateway proxies this call to the controller upstream, and for a few seconds after `systemctl restart automation-controller` that upstream is still marked down. Wait until `curl -sk https://localhost/api/controller/v2/ping/` returns `200`, then re-run — it's idempotent.

> **Two SSL traps here, both from the self-call to `localhost:8443`.** Without `REQUESTS_CA_BUNDLE` you get `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate` (certifi doesn't know our CA). With it, you might still get `Hostname mismatch, certificate is not valid for 'localhost'` — which is why Lab 6's gateway cert carries a `DNS:localhost` SAN. If you built that cert without `localhost`, reissue it (Lab 6) before this step.

## Verify — one login, whole platform

```bash
# the gateway answers on the platform port
curl -sk https://192.168.56.10/api/gateway/v1/ping/ | python3 -m json.tool

# the controller answers THROUGH the gateway, on the slug path
curl -sk -u "admin:${GW_PW}" \
  https://192.168.56.10/api/controller/v2/ping/ | python3 -m json.tool
# want: AWX's ping JSON — via envoy → (gateway auth over gRPC) → nginx → uwsgi

# and the Lab 17 job still runs through the platform door.
# look the template up by name — everything here goes through the gateway:
JT_ID=$(curl -sk -u "admin:${GW_PW}" \
  'https://192.168.56.10/api/controller/v2/job_templates/?name=Demo%20Job%20Template' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')
echo "job template: $JT_ID"

curl -sk -u "admin:${GW_PW}" -X POST \
  "https://192.168.56.10/api/controller/v2/job_templates/${JT_ID}/launch/" \
  | python3 -c 'import json,sys; print("job:", json.load(sys.stdin)["job"])'
```

(The lookup is worth as much as the launch: a `GET` with a query string, proxied and authenticated
the same way. If `JT_ID` comes back empty, the gateway isn't routing `/api/controller/` yet — fix
that before blaming the launch.)

That second curl is the whole platform in one line: envoy took the request on the platform port, checked it with jewel over the gRPC control plane, jewel attached a JWT, the route sent it to nginx, nginx to uwsgi, and AWX's jwt_consumer accepted the gateway's word for who you are. Every hop hand-built.

Now open **`https://192.168.56.10`** — no port — and log in as the gateway admin.

The console you built in [Lab 7](07-platform-ui.md) has grown a section. **Automation Execution**
is there now: projects, templates, inventories, jobs. You did not rebuild the UI, restart it, or
edit a single line of its config. The navigation is assembled from the gateway's service registry
at page load, and you just added a row to it.

That is the payoff for building the gateway first. Hub and EDA arrive in Labs 18–19 the same way:
build from source, register, refresh.

## Silence the false "subscription out of compliance" banner

The console shows a red banner — *"Your subscription is out of compliance"* — and it is spurious
on a from-source build. The UI renders it whenever `!awxConfig.license_info.compliant`, reading
the controller's `/api/controller/v2/config/`. But a source AWX
(`detect_server_product_name() == 'AWX'`) uses `OpenLicense`, whose `validate()` returns **no
`compliant` field at all** — and the UI reads missing as non-compliant. An open license is
unlimited; there is nothing to be out of compliance *with*. Make it say so:

```bash
sudo -u awx python3 - <<'PATCH'
import re
f = '/opt/awx/awx/main/utils/licensing.py'
s = open(f).read()
if 'compliant=True' in s:
    raise SystemExit('already patched — nothing to do')
new, n = re.subn(r'^(            valid_key=True,)$',
                 r'\1\n            compliant=True,', s, flags=re.M)
if n != 1:
    raise SystemExit(f'expected 1 match, found {n} — patch by hand')
open(f, 'w').write(new)
print('patched')
PATCH
sudo systemctl restart automation-controller
```

> **The guard matters.** A naive `sed` here is not idempotent — it matches `valid_key=True,` every
> time, so running it twice inserts `compliant=True,` twice and Python refuses the module with
> `SyntaxError: keyword argument repeated`. That failure is *deeply* misleading: the controller
> appears to start, uwsgi keeps serving because it imported the module before the second edit, and
> every other process crash-loops reporting `ValueError: Unable to configure formatter 'json'` —
> because Django's logging config imports `awx.main.utils`, which imports `licensing`. You go
> hunting for a logging problem that does not exist. The script above refuses to run twice.

The controller takes several seconds to come back, and until uwsgi is answering, envoy replies
`no healthy upstream` — **plain text, not JSON**. So poll rather than asking once:

```bash
for i in $(seq 1 12); do
  OUT=$(curl -sk -u "admin:${GW_PW}" https://192.168.56.10/api/controller/v2/config/)
  echo "$OUT" | python3 -c 'import json,sys; print("compliant:", json.load(sys.stdin)["license_info"]["compliant"])' 2>/dev/null && break
  echo "  not back yet: $(echo "$OUT" | head -c 40)"; sleep 3
done
# want: compliant: True
```

> **If it never turns True**, the failure modes read differently. A traceback ending in
> `JSONDecodeError: Expecting value: line 1 column 1` means the body wasn't JSON — the controller
> was still restarting, so wait. A `KeyError: 'license_info'` with an
> `{"detail": "Authentication credentials were not provided..."}` body means `$GW_PW` is empty or
> wrong in this shell. Only `compliant: False` means the patch didn't land:
> `sudo grep -n 'compliant=True' /opt/awx/awx/main/utils/licensing.py`.

Refresh the console and the banner is gone. This is a source patch like Lab 8's `devonly`
removal — it does not survive a `git pull` of `/opt/awx`, so re-apply it if you rebuild.

Next: [Smoke test](17-smoke-test.md)
