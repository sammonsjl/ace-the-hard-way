# Lab 6 — The automation controller

## What you will have at the end

AWX built from upstream source into an image you wrote, running as three containers with ten processes under supervisord configs you wrote, registered with the gateway and answering through the front door.

## Where it fits

This is the lab the whole track exists for.

Every containerized build of this platform you can actually obtain is a black box. The vendor's image is private. `quay.io/ansible/awx` is frozen at 24.6.1 — July 2024 — which predates the gateway and django-ansible-base resource-server integration this platform depends on. `ghcr.io/ansible/awx:devel` is a nightly nobody documents. If this lab pulled any of them, the tutorial would be lying about its most interesting component.

So you build it.

> **Build [Lab 7](07-execution.md)'s receptor image first.** AWX's own build copies the receptor binary in from a receptor image rather than compiling it, and this one does the same. It is a short Go build; go and do it now, then come back.
>
> That is not the only way the two labs are entangled — see *The dispatcher will not start* below.

## The Containerfile

AWX ships no plain Containerfile. It ships `tools/ansible/roles/dockerfile/templates/Dockerfile.j2`, 332 lines, rendered by `make Dockerfile`, plus three supervisor configs that are also templates. `containerfiles/controller/Containerfile` reproduces the end state of that template's production branch.

Four stages, the same shape as [Lab 5](05-gateway.md):

| Stage | Does |
|---|---|
| `awx-src` | clones [ansible/awx](https://github.com/ansible/awx) at `AWX_REF` |
| `ui-builder` | nodejs 18, `make ui` — the longest stage in the tutorial |
| `builder` | `make requirements_awx`, then `make sdist` and pip-install the result, then `collectstatic` |
| runtime | nginx, rsyslog, supervisor, dumb-init; the venv and receptor copied in |

Where AWX has a real build system, this uses it — `make ui`, `make requirements_awx`, `make sdist` are AWX's own targets and reimplementing them would teach nothing. Everything else is written here.

**`SETUPTOOLS_SCM_PRETEND_VERSION` is set explicitly.** AWX derives its version from git tags via setuptools-scm; a checkout at a bare commit has no tag to derive from, and the sdist build fails without it.

```bash
cd containerfiles/controller
podman build -t localhost/ace-controller:dev .
```

This is a long build. When it finishes:

```bash
podman run --rm --entrypoint "" localhost/ace-controller:dev sh -c \
  '/var/lib/awx/venv/awx/bin/pip show awx | head -2; ls /etc/supervisord_*.conf; ls -la /usr/bin/receptor'
```

**Want:** an AWX version, three supervisord configs, and a receptor binary.

### The supervisor configs

Three files, ten programs, written by hand:

| File | Programs |
|---|---|
| `supervisord_web.conf` | nginx, uwsgi, daphne, ws-heartbeat, awx-cache-clear |
| `supervisord_task.conf` | dispatcher, callback-receiver, wsrelay |
| `supervisord_rsyslog.conf` | awx-rsyslogd, awx-rsyslog-configurer |

That split is why the controller is **three containers off one image** rather than one container with ten processes. It is what the vendor's build does, and it means you can restart the task half without dropping anyone's web session.

Each file also carries a `superwatcher` event listener that runs `stop-supervisor` on `PROCESS_STATE_FATAL`. **This is the single most important thing to know when debugging this lab**: if one program dies for good, supervisord kills the entire container. The failure you see in `systemctl --user status` is always the *consequence*; the cause is further up the log.

## Certificate and configuration

```bash
~/ace/tls/ace-cert tower awx ace-controller cert
```

Note the arguments: directory `awx`, hostname `ace-controller`. They differ here, which is exactly the case [Lab 3](03-internal-ca.md) warns about.

```bash
mkdir -p ~/ace/awx/conf.d
cd ~/ace/awx
openssl rand -base64 48 | tr -d '\n' > SECRET_KEY
chmod 0600 SECRET_KEY
podman secret create ace-awx-secret-key SECRET_KEY
```

Then `settings.py` and three fragments in `conf.d/`. The interesting settings:

```python
ANSIBLE_BASE_JWT_KEY = 'https://ace-gateway'
RESOURCE_SERVER__URL = 'https://ace-gateway'
OPTIONAL_API_URLPATTERN_PREFIX = "controller"
```

Both URLs point at **envoy**, not at the gateway's own nginx on 8446. The controller validates JWTs minted for requests that arrived through the front door, so the issuer it trusts has to be the front door. And `OPTIONAL_API_URLPATTERN_PREFIX` exists because the gateway serves the controller at `/api/controller/` while the controller serves itself at `/api/` — the controller has to know the prefix its own links should carry.

### The Redis cache backend the bundle names does not exist

`conf.d/redis.py` looks obvious and is the one place the vendor's 2.7 templates are simply out of date:

```python
BROKER_URL = 'unix:///run/redis/redis.sock?db=0'
CACHES = {
    'default': {
        'BACKEND': 'ansible_base.lib.cache.redis_cache.DABRedisCache',
        'LOCATION': 'unix:///run/redis/redis.sock?db=1'
    }
}
```

The bundle writes `awx.main.cache.AWXRedisCache`. That module has been removed from current AWX — the implementation moved into django-ansible-base — and using it gives you, at import time, before anything else runs:

```
InvalidCacheBackendError: Could not find backend 'awx.main.cache.AWXRedisCache':
No module named 'awx.main.cache'
```

Check what your build actually ships rather than trusting either source:

```bash
podman run --rm --entrypoint "" localhost/ace-controller:dev \
  grep -n "^CACHES" /var/lib/awx/venv/awx/lib64/python3.12/site-packages/awx/settings/defaults.py
```

Note also that both URLs are the **unix socket**, not the TCP port — which is why [Lab 4](04-postgresql.md) built one.

### nginx here is 1.20, not 1.24

The gateway image installs nginx from the `nginx:1.24` module. This image takes the AppStream default, which is **1.20.1**. So `~/ace/awx/nginx.conf` writes:

```
listen 8443 default_server ssl http2;
```

and not the standalone `http2 on;` directive, which arrived in nginx 1.25. Get it wrong and nginx refuses to start with `unknown directive "http2"`, supervisord's `superwatcher` fires, and the whole container exits — a config typo that presents as a container that will not stay up.

## Migrations, and registering the instance by hand

```bash
podman run --rm --network host --userns keep-id:uid=1000,gid=0 \
  -v ~/ace/awx/settings.py:/etc/tower/settings.py:ro,Z \
  -v ~/ace/awx/conf.d:/etc/tower/conf.d:ro,Z \
  -v ~/ace/awx/SECRET_KEY:/etc/tower/SECRET_KEY:ro,Z \
  -v ~/ace/redis/run:/run/redis:Z \
  -v ~/ace/tls/extracted:/etc/pki/ca-trust/extracted:z \
  --entrypoint "" localhost/ace-controller:dev \
  awx-manage migrate --noinput
```

Then register this machine as an instance:

```bash
# same run line as above, but ending:
  awx-manage provision_instance --hostname ace-controller --node_type hybrid
```

**Want:** `Successfully registered instance ace-controller`.

`RESOURCE_SERVER['SECRET_KEY'] is not configured` appears repeatedly throughout both commands. It is a warning about reverse-sync to the gateway, not a failure, and everything in this lab works without it.

### Why the instance is registered by hand

The image's `launch_awx_task.sh` calls `awx-manage provision_instance` with no arguments. That form reads the node's identity out of Kubernetes-specific settings, so outside a cluster it fails:

```
CommandError: Registering with values from settings only intended for use in K8s installs
```

So the task container gets a launch script of your own — identical to AWX's except that the `provision_instance` line is gone, because you just did it by hand with an explicit `--hostname`:

```bash
vim ~/ace/awx/launch-task.sh    # id/passwd shim, wait-for-migrations, exec supervisord
```

## The quadlets

Three containers, one image. All three share the same config mounts; the web container adds nginx and the certificate.

```bash
vim ~/.config/containers/systemd/ace-awx-web.container      # Exec=launch_awx_web.sh
vim ~/.config/containers/systemd/ace-awx-task.container     # Exec=/usr/local/bin/launch-task.sh
vim ~/.config/containers/systemd/ace-awx-rsyslog.container  # Exec=launch_awx_rsyslog.sh
```

```bash
systemctl --user daemon-reload
systemctl --user start ace-awx-web ace-awx-task ace-awx-rsyslog
```

### The dispatcher will not start without a receptor config

The first time the task container comes up it dies with:

```
CommandError: Receptor config not found after 10s
```

`awx-manage dispatcherd` checks for `/etc/receptor/receptor.conf` before it will run, and gives up after ten seconds. **This is where the bare-metal track's clean split between Lab 6 and Lab 7 stops holding.** There, the controller happily runs with no execution plane and every job sits in `pending`; here, the control plane will not start at all until receptor's configuration exists.

So the work-signing keypair and `receptor.conf` are created now, in this lab, and mounted into the controller containers:

```bash
mkdir -p ~/ace/receptor/run
cd ~/ace/receptor
openssl genrsa -out work_private_key.pem 4096
openssl rsa -in work_private_key.pem -pubout -out work_public_key.pem
chmod 0640 work_private_key.pem
vim receptor.conf
```

The config is a single `local-only` node: a control service on a unix socket, a `work-command` that runs `ansible-runner worker`, and the work-signing key. There is no `tls-client` section and no mesh CA, because there is no second node to authenticate to — [Lab 7](07-execution.md) explains what a second node would restore.

The controller holds the **private** key and signs each work unit; receptor holds the **public** key and verifies it. That asymmetry is the whole point, and it is why the two files have different modes.

```bash
systemctl --user daemon-reload
systemctl --user restart ace-awx-task
podman exec ace-awx-task supervisorctl -c /etc/supervisord_task.conf status
```

**Want:** `dispatcher`, `callback-receiver` and `wsrelay` all `RUNNING`.

## Verify

```bash
podman exec ace-awx-web supervisorctl -c /etc/supervisord_web.conf status
podman exec ace-awx-rsyslog supervisorctl -c /etc/supervisord_rsyslog.conf status
podman exec ace-awx-task awx-manage list_instances
```

**Want:** five web programs, two rsyslog programs, and an instance line like

```
ace-controller capacity=136 node_type=hybrid version=25.0.0 heartbeat="..."
```

A non-zero capacity and a fresh heartbeat mean the dispatcher is alive and talking to the database. Then, directly:

```bash
curl --cacert ~/ace/tls/extracted/pem/tls-ca-bundle.pem https://ace-controller:8443/api/
```

**Want:** `{"description":"AWX REST API","current_version":"/api/v2/", ...}`.

## Registration

Same four-object shape as the gateway, one lab on. `service_type` 2 is `controller`:

```bash
A="admin:$(cat ~/ace/gateway/pw-admin)"
C=~/ace/tls/extracted/pem/tls-ca-bundle.pem
B=https://ace-gateway:8446/api/gateway/v1
post () { curl -sS -u "$A" --cacert $C -H 'Content-Type: application/json' -X POST "$B/$1/" -d "$2"; }

post service_clusters '{"name":"controller","service_type":2}'
post service_nodes    '{"name":"Node controller - ace-controller","service_cluster":2,"address":"ace-controller"}'
post services         '{"name":"controller api","api_slug":"controller","http_port":1,"service_cluster":2,
                        "is_service_https":true,"service_path":"/api/controller/","service_port":8443,"order":1}'
```

Wait five seconds for envoy's next xDS refresh, then go through the **front door**:

```bash
curl -u "$A" --cacert $C https://ace-gateway/api/controller/v2/ping/
```

**Want:** the controller's ping, listing `ace-controller` as a hybrid node with a capacity and a heartbeat.

That single request is the whole platform working at once. Envoy accepted it on 443, asked the gateway over gRPC whether it was allowed, rewrote `/api/controller/` to `/api/` using the Lua script you wrote in [Lab 5](05-gateway.md) — this is the first route where that script does real work — and proxied it to a controller that authenticated the caller from a JWT the gateway signed.

Open `https://ace-gateway/` and log in. **Automation Execution** is now in the sidebar, because the registry has two services in it instead of one.

And every job you launch will sit in `pending` forever, because nothing is running receptor yet.

Next: [Execution: receptor and podman](07-execution.md)
