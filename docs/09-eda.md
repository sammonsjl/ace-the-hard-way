# Lab 9 — Event-Driven Ansible

## What you will have at the end

eda-server built from upstream source, running as four containers behind nginx, registered with the gateway and answering on `/api/eda/`.

## Where it fits

Last component. By now the pattern needs no explanation — the value here is that EDA is built a different way from everything else, and the differences are worth seeing.

## The Containerfile

A usable multi-arch upstream image exists (`quay.io/ansible/eda-server`). We build it anyway: an image you did not build is a component you did not learn.

Two stages, and one thing that sets this build apart from every other image in the tutorial:

**eda-server declares its dependencies with poetry, not pip.** So poetry is what installs them:

```dockerfile
RUN ${PYTHON_BIN} -m pip install --user "poetry==${POETRY_VERSION}" && \
    ${PYTHON_BIN} -m venv "$VIRTUAL_ENV" && \
    poetry config virtualenvs.create false
```

`virtualenvs.create false` makes poetry install into the venv we just created rather than one of its own. And dependencies are installed **before** the source is copied in:

```dockerfile
COPY --from=eda-src /src/poetry.toml /src/pyproject.toml /src/poetry.lock $SOURCES_DIR/
RUN poetry install -E all --no-root --no-cache
COPY --from=eda-src /src $SOURCES_DIR/
RUN poetry install -E all --only-root
```

`--no-root` installs the dependency tree without the project; `--only-root` then installs just the project. A change to eda-server's source does not re-resolve anything.

Note the contrast with [Lab 8](08-hub.md): hub's pins had to be fought into submission because its lockfile was stale against PyPI. EDA's `poetry.lock` installs cleanly first time. Same problem, two projects, opposite outcomes — the lockfile is only as good as the discipline behind it.

## Configuration

EDA reads a YAML file, not a Python module: `EDA_SETTINGS_FILE`, defaulting to `/etc/eda/settings.yaml`.

```bash
~/ace/tls/ace-cert server eda ace-eda cert
mkdir -p ~/ace/eda && cd ~/ace/eda
openssl rand -base64 48 | tr -d '\n' > SECRET_KEY && chmod 0600 SECRET_KEY
podman secret create ace-eda-secret-key SECRET_KEY
vim settings.yaml
```

The gateway keys are the same three as everywhere else, pointed at the front door. One thing is genuinely different:

```yaml
MQ_HOST: 127.0.0.1
MQ_PORT: 6379
MQ_DB: 5
```

**EDA is the only component that reaches Redis over the TCP port** rather than the unix socket. The gateway uses TCP too in this build, but the controller uses the socket — which is why [Lab 4](04-postgresql.md) configured both.

## Migrations, service key, quadlets

```bash
podman run --rm --network host --userns keep-id:uid=1001,gid=0 \
  -v ~/ace/eda/settings.yaml:/etc/eda/settings.yaml:ro,Z \
  -v ~/ace/eda/SECRET_KEY:/etc/eda/SECRET_KEY:ro,Z \
  -v ~/ace/tls/extracted:/etc/pki/ca-trust/extracted:z \
  -e REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem \
  --entrypoint "" localhost/ace-eda:dev aap-eda-manage migrate --noinput
```

Note `uid=1001`: eda-server's image builds its user at 1001, not 1000. Every other image in this tutorial uses 1000, and using it here gives permission errors on `/app`.

```bash
podman exec ace-gateway aap-gateway-manage generate_service_secret eda
```

passed to the containers as `EDA_RESOURCE_SERVER__SECRET_KEY`.

| Unit | Process | Port |
|---|---|---|
| `ace-eda-api` | `gunicorn aap_eda.wsgi:application` | 8000 |
| `ace-eda-ws` | `daphne aap_eda.asgi:application` | 8001 |
| `ace-eda-scheduler` | `aap-eda-manage scheduler` | — |
| `ace-eda-worker` | `aap-eda-manage dispatcherd --worker-class DefaultWorker` | — |
| `ace-eda-activation-worker` | `aap-eda-manage dispatcherd --worker-class ActivationWorker` | — |
| `ace-eda-web` | nginx | 8445 |

nginx routes `/api/eda/ws/` to daphne and everything else to gunicorn — the same websocket split the controller has, for the same reason.

## Registration and verify

```bash
post service_clusters '{"name":"eda","service_type":4}'
post service_nodes    '{"name":"Node eda - ace-eda","service_cluster":3,"address":"ace-eda"}'
post services         '{"name":"eda api","api_slug":"eda","http_port":1,"service_cluster":3,
                        "is_service_https":true,"service_path":"/api/eda/","service_port":8445,"order":3}'
```

```bash
curl --cacert $C https://ace-eda:8445/api/eda/v1/status/          # directly
curl -u "$A" --cacert $C https://ace-gateway:9443/api/eda/v1/status/   # through the front door
```

Both should answer. If the second says `no healthy upstream`, restart envoy — see the note at the end of [Lab 8](08-hub.md); the health check remembers a failure from before the service was up.

## Two workers, and the argument with no default

EDA runs **two** dispatchers, and the difference matters: `DefaultWorker` handles general tasks, `ActivationWorker` runs rulebook activations. With only one of them, or none, the status endpoint reports:

```json
{"status": "degraded", "message": "Dispatcherd workers unavailable"}
```

`aap-eda-manage rqworker` still exists in the image and looks like the obvious command, but the status check looks for a **dispatcherd** — the queue implementation moved and the old entry point outlived it.

The trap is what happens when you get to `dispatcherd` and stop there:

```
aap-eda-manage dispatcherd: error: the following arguments are required: --worker-class
```

**`--worker-class` is required and has no default.** Omitting it makes the command print its entire settings dump — dozens of lines that look exactly like a healthy startup — and *then* exit 2 on an argparse error. Under a quadlet with `Restart=on-failure` that is a container which starts, logs what appears to be a successful boot, and dies, forever, with no error anywhere in `journalctl`.

The way to see it is to stop asking systemd and run the command yourself:

```bash
podman run --rm --network host --userns keep-id:uid=1001,gid=0 \
  -v ~/ace/eda/settings.yaml:/etc/eda/settings.yaml:ro,Z \
  -v ~/ace/eda/SECRET_KEY:/etc/eda/SECRET_KEY:ro,Z \
  -v ~/ace/tls/extracted:/etc/pki/ca-trust/extracted:z \
  --entrypoint "" localhost/ace-eda:dev \
  aap-eda-manage dispatcherd
```

The usage message is on the last line, after everything that looked fine. This is the third time in this tutorial that a container's real error died with the container — the others were [Lab 4](04-postgresql.md)'s postgres initialization and [Lab 6](06-controller.md)'s AWX migration — and the technique is the same every time: take the process out of the unit and run it in the foreground.

With both workers up:

```bash
curl -u "$A" --cacert $C https://ace-gateway:9443/api/eda/v1/status/
```

**Want:** `{"status":"good"}`.

## The decision environment

Rulebook activations run in a **decision environment** — the same idea as an execution environment, different contents: `ansible-rulebook` instead of `ansible-core` plus collections.

```bash
cd containerfiles/de-supported
podman build -t localhost/ace-de-supported:dev .
```

One thing in that Containerfile is worth knowing: **it installs a JVM.** `ansible-rulebook`'s event engine is Drools, reached through jpy, so a DE is a Java runtime wearing a Python coat. It is why the image is noticeably larger than the EE.

Activations start their DE containers through `PODMAN_SOCKET_URL`, which is the same nested-rootless-podman problem [Lab 7](07-execution.md) works through in detail — and the settings that solved it there are the place to start here.

## What you have now

Five components, all built from upstream source, all behind one login:

```bash
curl -u "$A" --cacert $C https://ace-gateway:9443/api/controller/v2/ping/
curl -u "$A" --cacert $C https://ace-gateway:9443/api/galaxy/pulp/api/v3/status/
curl -u "$A" --cacert $C https://ace-gateway:9443/api/eda/v1/status/
curl http://127.0.0.1:9901/clusters | grep health_flags
```

**Want:** three services answering, and four `healthy` clusters in envoy.

Open `https://ace-gateway:9443/` and log in. Automation Execution, Automation Content and Automation Decisions are all in the sidebar — because the registry has four services in it, and the navigation is assembled from the registry at page load.

— [Cleanup](99-cleanup.md) · [Glossary](glossary.md)
