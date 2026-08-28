# Lab 5 — The platform gateway

## What you will have at the end

Your first image built from upstream source — the gateway API and the platform console, compiled in front of you — running behind envoy on `https://ace-gateway`, with a front door that opens because the gateway told envoy to open it.

## Where it fits

This is the **build** pattern lab. [Lab 4](04-postgresql.md) configured images other people made; from here on you write the Containerfile.

The gateway is the right place to learn it because it is the hardest interesting case: two upstream repos built in separate stages and assembled into one runtime image, a Python venv, nginx, supervisor, uwsgi, and a static UI that has to be compiled by node and then copied into an image with no node in it.

It is also where the platform stops being a collection of services and becomes a platform. Envoy holds almost no configuration of its own — its listeners and routes arrive from the gateway's service registry over xDS, and every request it proxies is authorised by a gRPC call back to the gateway. Nothing in this lab is a reverse proxy pointed at something.

## The build pattern

Four rules, and they hold for every image in [`containerfiles/`](../containerfiles/README.md):

- **Pin the upstream ref.** Every source repo is cloned at a commit, declared as an `ARG` so it can be overridden per build. A moving branch is not reproducible.
- **Multi-stage, always.** Build tools do not belong in a runtime image. Node compiles the console in one stage and does not exist in the final one.
- **Nothing secret is `COPY`'d.** Keys and passwords are mounted at run time. A layer is a thing you can push and unpack.
- **EL9 base.** From here on your host's distro stops mattering.

## The Containerfile

`containerfiles/gateway/Containerfile` is the finished file — a Containerfile has to exist on disk before `podman build` can read it, so this track ships them rather than pretending you can type one into a build ([why](../containerfiles/README.md)). Open it alongside this section. Four stages:

| Stage | Does |
|---|---|
| `jewel-src` | clones [ansible/jewel](https://github.com/ansible/jewel) at `JEWEL_REF` — source only, no build |
| `ui-builder` | clones [ansible/ansible-ui](https://github.com/ansible/ansible-ui), `npm ci`, builds `platform/` with vite |
| `builder` | CentOS Stream 9, `python3.12 -m venv`, installs jewel's `requirements.txt` and `requirements_git.txt` |
| runtime | nginx 1.24, supervisor, uwsgi, `dumb-init` as PID 1, the venv and the console copied in, `collectstatic` baked |

Four things in it are worth understanding rather than skimming:

- **The console is built here rather than pulled** because the published platform-UI image is private. This stage is why [Lab 1](01-prerequisites.md) tells you not to build and run at once: `NODE_OPTIONS=--max-old-space-size=8192`.
- **`uid 1000 / gid 0`** for the `gateway` user. Group-root with `chmod g+rwx` on the runtime directories is how the image stays writable when the UID it runs as changes.
- **`PROTOCOL_BUFFERS_PYTHON_IMPLEMENTATION=python`** — the xDS protobuf definitions need the pure-Python implementation to stay compatible with protobuf 3.21+.
- **`collectstatic` at build time**, with `GATEWAY_SECRET_KEY_FILE=/dev/null` because collecting static files does not need a real key. The startup script runs it again; baking it makes that a fast no-op.

```bash
cd containerfiles/gateway
podman build -t localhost/ace-gateway:dev .
```

This takes a while — the npm install and the venv are both long. When it finishes:

```bash
podman run --rm --entrypoint "" localhost/ace-gateway:dev \
  sh -c 'python3.12 -V; ls /opt/aap_gateway/; nginx -v'
```

**Want:** Python 3.12, a directory listing containing `venv`, `src`, `static` and `platform_ui`, and nginx 1.24.

> **A directory the image must create, that jewel's own build does not.** The gateway's fallback cache is a file-based Django cache under `/var/cache/ansible-automation-platform/gateway`, and Django creates it at *import* time — before any of your configuration runs. The runtime user cannot create a directory under `/var/cache`, so if the image does not already contain it, every management command dies during Django's system checks with
> ```
> PermissionError: [Errno 13] Permission denied: '/var/cache/ansible-automation-platform'
> ```
> which appears, unhelpfully, as a *migration* failure. It is in the `mkdir` loop in the runtime stage for this reason.

## The certificate

```bash
~/ace/tls/ace-cert gateway gateway ace-gateway cert
```

That writes `~/ace/gateway/tls/gateway.cert` and `.key`, with `ace-gateway` in the SAN. Remember it is mounted, never built in.

## Configuration

### The shipped configs are development defaults, and two of them collide

The image carries jewel's own `nginx-gateway.conf` and `uwsgi.ini`. Read them before using them:

```bash
podman run --rm --entrypoint "" localhost/ace-gateway:dev \
  grep -E "listen|socket =" /etc/ansible-automation-platform/gateway/nginx-gateway.conf \
                            /etc/ansible-automation-platform/gateway/uwsgi.ini
```

nginx listens on **8000**, and uwsgi binds **127.0.0.1:8050**.

On jewel's own laptop that is fine. Here it is not: 8050 is `controller_uwsgi_port`, and in [Lab 6](06-controller.md) the controller will want it. On five machines that collision cannot happen, because each service owns its own ports on its own host. In one network namespace it is a real conflict, and it is the clearest illustration of what "the port map is the topology" means.

So you write both files, changing two numbers and dropping jewel's `runserver` debug fallback:

```bash
vim ~/ace/gateway/uwsgi.ini            # socket = 127.0.0.1:8052
vim ~/ace/gateway/nginx-gateway.conf   # listen 8446; upstream uwsgi -> localhost:8052
```

### Settings

```bash
vim ~/ace/gateway/settings.py
```

This file is loaded *after* jewel's defaults, which is why it can index into `CACHES` and `LOGGING` — those structures already exist. It points the gateway at `ace-db`, disables the Redis cluster and TLS paths (we run one Redis on loopback), and sets the gRPC port to 50051.

The database password is *not* in it. The gateway reads `DATABASE_PASSWORD` from the environment, `REDIS_URL` likewise, and its Django secret from the file named by `GATEWAY_SECRET_KEY_FILE` — all three arrive as podman secrets.

```bash
cd ~/ace/gateway
openssl rand -base64 24 | tr -d '/+=' | head -c 24 > pw-admin
openssl rand -base64 48 | tr -d '/+=' | head -c 50 > secret-key
printf 'redis://127.0.0.1:6379/4' > redis-url
chmod 0600 pw-admin secret-key redis-url

podman secret create ace-gw-admin      pw-admin
podman secret create ace-gw-secret-key secret-key
podman secret create ace-gw-redis-url  redis-url
podman secret create ace-gw-dbpass     ~/ace/postgresql/pw-gateway
```

The startup script seeds the admin account from `container-startup.yml`, which it reads from inside the image:

```bash
cat > ~/ace/gateway/container-startup.yml <<EOF
gateway_admin_username: admin
gateway_admin_password: $(cat ~/ace/gateway/pw-admin)
EOF
chmod 0600 ~/ace/gateway/container-startup.yml
```

## The quadlet

```bash
vim ~/.config/containers/systemd/ace-gateway.container
```

```ini
[Unit]
Description=ACE platform gateway — jewel plus the console, built from source
Requires=ace-postgres.service ace-redis.service
After=ace-postgres.service ace-redis.service

[Container]
ContainerName=ace-gateway
Image=localhost/ace-gateway:dev
Network=host
UserNS=keep-id:uid=1000,gid=0
Environment=CONTAINER_NUMBER=1
Environment=GATEWAY_SECRET_KEY_FILE=/etc/ansible-automation-platform/gateway/SECRET_KEY
Secret=ace-gw-dbpass,type=env,target=DATABASE_PASSWORD
Secret=ace-gw-redis-url,type=env,target=REDIS_URL
Secret=ace-gw-secret-key,type=mount,target=/etc/ansible-automation-platform/gateway/SECRET_KEY,mode=0440
Volume=%h/ace/gateway/settings.py:/etc/ansible-automation-platform/gateway/settings.py:ro,Z
Volume=%h/ace/gateway/uwsgi.ini:/etc/ansible-automation-platform/gateway/uwsgi.ini:ro,Z
Volume=%h/ace/gateway/nginx-gateway.conf:/etc/ansible-automation-platform/gateway/nginx-gateway.conf:ro,Z
Volume=%h/ace/gateway/container-startup.yml:/opt/aap_gateway/src/container-startup.yml:ro,Z
Volume=%h/ace/gateway/tls/gateway.cert:/etc/ansible-automation-platform/gateway/gateway.crt:ro,Z
Volume=%h/ace/gateway/tls/gateway.key:/etc/ansible-automation-platform/gateway/gateway.key:ro,Z
Volume=%h/ace/tls/extracted:/etc/pki/ca-trust/extracted:z

[Service]
Restart=on-failure
TimeoutStartSec=600

[Install]
WantedBy=default.target
```

**`keep-id:uid=1000,gid=0`** maps *your* UID to the image's `gateway` user rather than to root — which is what makes the mounted configs readable by the process that needs them. This is the general form of the rule [Lab 4](04-postgresql.md) hit from the wrong side.

**`CONTAINER_NUMBER=1`** is how the startup script decides it is the node responsible for running migrations and creating the superuser. In a multi-node deployment only one container gets a 1.

```bash
systemctl --user daemon-reload
systemctl --user start ace-gateway
podman logs -f ace-gateway
```

First start runs every migration, so give it a few minutes. Watch for:

```
Superuser created successfully.
[...] >>>>>>>> Admin password: ...
```

Then:

```bash
podman exec ace-gateway supervisorctl status
```

**Want:** `nginx`, `uwsgi`, `control-plane` and `dispatcher` all `RUNNING`. That is the supervisor family, inside the container, exactly as the vendor's own build runs it.

```bash
curl --cacert ~/ace/tls/extracted/pem/tls-ca-bundle.pem \
  https://ace-gateway:8446/api/gateway/v1/ping/
```

**Want:** `{"status":"good", ..., "db_connected":true, "dispatcherd_connected":true}` — and note `--cacert` pointing at the bundle from [Lab 3](03-internal-ca.md). Nothing here is `-k`.

## Registration — the part that is not a proxy config

The gateway is up, but envoy has nothing to serve. Envoy's listeners and routes are **rows in the gateway's registry**, delivered over xDS. So you create them:

```bash
A="admin:$(cat ~/ace/gateway/pw-admin)"
C=~/ace/tls/extracted/pem/tls-ca-bundle.pem
B=https://ace-gateway:8446/api/gateway/v1
post () { curl -sS -u "$A" --cacert $C -H 'Content-Type: application/json' -X POST "$B/$1/" -d "$2"; }

post http_ports      '{"name":"port-443","number":443,"use_https":true,"is_api_port":true}'
post service_clusters '{"name":"gateway","service_type":1}'
post service_nodes    '{"name":"Node gateway - ace-gateway","service_cluster":1,"address":"ace-gateway"}'
post services         '{"name":"gateway api","api_slug":"gateway","http_port":1,"service_cluster":1,
                        "is_service_https":true,"service_path":"/","service_port":8446,
                        "order":100,"enable_gateway_auth":false}'
```

Four objects, and the shape matters:

- **`http_ports`** *is* the envoy listener. Port 443 exists because this row exists.
- **`service_types`** are seeded by the migrations — `gateway`, `controller`, `hub`, `eda` are ids 1 to 4. Check with `curl -u "$A" --cacert $C $B/service_types/`; the API wants the primary key, not the name.
- **`service_clusters`** and **`service_nodes`** are the "what" and the "where".
- **`services`** is the route: this path prefix, on that port, to this cluster's port.

Every later lab adds one cluster, one node and one service. That is all "registering with the gateway" ever means.

## Envoy

```bash
mkdir -p ~/ace/envoy
vim ~/ace/envoy/envoy.yaml
```

The config is almost empty on purpose: `dynamic_resources` pointing CDS and LDS at the gateway, and exactly two static clusters —

- **`gateway-control-plane-rest`** → `ace-gateway:8446` over TLS. Where the routes come from.
- **`gateway_control_plane`** → `127.0.0.1:50051` over HTTP/2. Who authorises each request.

### The Lua file the gateway image does not ship

The gateway's LDS response includes a Lua filter that loads a script by *filename* on envoy's side. It does not send the script, and the script is not in the gateway image — the vendor ships it in the **proxy** image, at `/etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua`. Since we assemble our own envoy image, we write it.

The route metadata says what it has to do. Each route carries `prefix` (the path clients use) and `prefix_rewrite` (the path the service uses), and the script translates between them **in both directions**.

The direction that is easy to miss is the response. Envoy's own route configuration already rewrites the request path, so the script must not touch it — what the script handles is every *other* place a path appears: query-parameter values, request bodies, `Location` headers, and response bodies. Without the response half, a service that returns a redirect or embeds an absolute URL sends the client to a path envoy does not serve.

Three cases have to be skipped or they break: websocket upgrade requests, completed upgrades (`:status` 101), and `text/event-stream` responses — reading a streaming body to rewrite it is the same as buffering it.

```bash
vim ~/ace/envoy/envoy-path-rewrite.lua
```

It lives at `~/ace/envoy/envoy-path-rewrite.lua` and is reproduced in full above. Without it, envoy rejects every listener the gateway sends with `Invalid path: /etc/envoy/envoy-path-rewrite.lua`. The gateway service itself does not need a rewrite — its `service_path` and `gateway_path` are both `/` — but the filter is attached at the listener, so the file has to exist before *any* route loads. [Lab 6](06-controller.md) is where it starts doing real work, mapping `/api/controller/` to `/api/`.

### The quadlet

```ini
[Unit]
Description=ACE envoy — the single front door
Requires=ace-gateway.service
After=ace-gateway.service

[Container]
ContainerName=ace-envoy
Image=docker.io/envoyproxy/envoy:v1.38.4
Network=host
UserNS=keep-id:uid=101,gid=101
Volume=%h/ace/envoy/envoy.yaml:/etc/envoy/envoy.yaml:ro,Z
Volume=%h/ace/envoy/envoy-path-rewrite.lua:/etc/envoy/envoy-path-rewrite.lua:ro,Z
Volume=%h/ace/gateway/tls/gateway.cert:/etc/ansible-automation-platform/gateway/gateway.crt:ro,Z
Volume=%h/ace/gateway/tls/gateway.key:/etc/ansible-automation-platform/gateway/gateway.key:ro,Z
Volume=%h/ace/tls/extracted:/etc/pki/ca-trust/extracted:z
Exec=envoy -c /etc/envoy/envoy.yaml --service-cluster envoy

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

> **`dns_lookup_family: V4_ONLY` is not optional, and leaving it out looks like a version problem.** `ace-gateway` resolves to *both* `127.0.0.1` and `::1` on a dual-stack host, and envoy will pick the IPv6 address. Every service here listens on IPv4, so the connection is refused — and what you see is
> ```
> REST update for /v3/discovery:clusters failed
> ```
> repeating forever, with envoy never binding 443. Nothing in that message mentions addresses. Turn on `--component-log-level connection:debug` and the real line appears: `connecting to [::1]:8446 ... Connection refused`.
>
> The [bare-metal track](../../../tree/main/docs/05-gateway.md) never hits this because it points the cluster at a literal `127.0.0.1` rather than a name. Using names is worth the one extra setting — it is what keeps the certificates in [Lab 3](03-internal-ca.md) meaningful.

Two details that will otherwise cost you an hour:

- **The certificate is mounted at the gateway's path, not envoy's.** The listener config comes from the gateway, so it names the paths the *gateway* uses — `/etc/ansible-automation-platform/gateway/gateway.crt`. Mount it anywhere else and envoy reports `Failed to load incomplete private key`, naming a path you never chose.
- **`keep-id:uid=101,gid=101`.** The envoy image runs as uid 101. Your key is `0640` and owned by you, so without this mapping envoy cannot read it — and the error is the same "incomplete private key", which is not what a permission problem usually sounds like.

```bash
systemctl --user daemon-reload
systemctl --user start ace-envoy
podman logs ace-envoy | grep -E "lds:|rejected"
```

**Want:** `lds: add/update listener 'port-443'` and no `rejected` lines.

## Verify

```bash
C=~/ace/tls/extracted/pem/tls-ca-bundle.pem

curl -o /dev/null -w "console: %{http_code}\n" --cacert $C https://ace-gateway/
curl -o /dev/null -w "unauthenticated api: %{http_code}\n" --cacert $C https://ace-gateway/api/gateway/v1/me/
curl --cacert $C https://ace-gateway/api/gateway/v1/ping/
```

**Want:** `200` for the console, **`401`** for the API, and a ping reporting `"proxy_connected":true`.

The 401 is the interesting one. Envoy did not decide that — it asked the gateway over gRPC, on 50051, and relayed the answer. That is the `ext_authz` filter working, and it is the difference between a proxy and a platform.

`"proxy_connected":true` is the other direction: the gateway can see that an envoy is talking to it.

Open `https://ace-gateway/` in a browser. You will get a certificate warning unless you have added the CA from [Lab 3](03-internal-ca.md) to your browser or system trust store — the platform trusts it, your desktop does not. Log in as `admin` with the password in `~/ace/gateway/pw-admin`.

**Want:** the console, with exactly one thing in the sidebar. The controller, hub and EDA are not there because they do not exist yet — the navigation is assembled from the service registry, and right now the registry has one service in it.

Next: [The automation controller](06-controller.md)
