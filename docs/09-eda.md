# Lab 9 — Event-Driven Ansible

## What you will have at the end

eda-server built from upstream source, running as four containers behind nginx, registered with the gateway and answering on `/api/eda/`.

## Where it fits

Last component. By now the pattern needs no explanation — the value here is that EDA is built a different way from everything else, and the differences are worth seeing.

## The Containerfile

A usable multi-arch upstream image exists (`quay.io/ansible/eda-server`). We build it anyway: an image you did not build is a component you did not learn.

Two stages, and one thing that sets this build apart from every other image in the tutorial:

**eda-server declares its dependencies with poetry — but poetry is not how the vendor installs it, and not how we do either.**

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
curl -u "$A" --cacert $C https://ace-gateway/api/eda/v1/status/   # through the front door
```

`status` does not prove single sign-on — it answers without a token. To confirm the JWT path actually works, ask EDA who you are:

```bash
curl -u "$A" --cacert $C https://ace-gateway/api/eda/v1/users/me/
```

**Want:** the gateway's `admin`, carrying a `resource.ansible_id`. That UUID is issued by the gateway and shared across every service, so seeing it here means EDA validated a JWT the gateway signed and resolved it to the same identity — not that it happens to have a local user with the same name.

> EDA's django-ansible-base comes from `poetry.lock`, so it trails the version the gateway, hub and controller share. That is tolerable — verified here — but it is the first thing to check if `users/me` ever returns a JWT claim error. See the DAB generation check in [Lab 8](08-hub.md).

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
curl -u "$A" --cacert $C https://ace-gateway/api/eda/v1/status/
```

**Want:** `{"status":"good"}`.

## The decision environment

Rulebook activations run in a **decision environment** — the same idea as an execution environment, different contents: `ansible-rulebook` instead of `ansible-core` plus collections.

```bash
cd containerfiles/de-supported
podman build -t localhost/ace-de-supported:dev .
```

One thing in that Containerfile is worth knowing: **it installs a JVM.** `ansible-rulebook`'s event engine is Drools, reached through jpy, so a DE is a Java runtime wearing a Python coat:

```
ansible-rulebook [1.1.7]
  Drools_jpy version = 0.3.10
  Java home = /usr/lib/jvm/jre-17-openjdk
```

That is why it is roughly twice the size of the EE.

## Somewhere to keep a rulebook

EDA projects are git repositories, and the URL has to be one EDA accepts. Two attempts fail before one works:

- **`file:///...`** — `Invalid source control URL: Unsupported scheme 'file'`.
- **Dumb HTTP** (a bare repo behind plain nginx with `git update-server-info`) — EDA clones with `--depth`, and `fatal: dumb http transport does not support shallow capabilities`.

So the lab runs a `git daemon`, which speaks `git://` and supports shallow clones. There is one trap in building it:

> **`git daemon` is not part of the `git` package on EL9.** It ships separately in `git-daemon`. Every image in this tutorial has git and none of them can run `git daemon` — you get `git: 'daemon' is not a git command`, which reads like a typo rather than a missing package.

`containerfiles/git-server/` is four lines for that reason.

```bash
mkdir -p ~/ace/eda/projects/ace-rulebooks/rulebooks
vim ~/ace/eda/projects/ace-rulebooks/rulebooks/hello.yml
```

```yaml
- name: ACE rulebook smoke test
  hosts: all
  sources:
    - ansible.eda.generic:
        payload:
          - message: "hello from a rulebook"
        loop_count: 1
        shutdown_after: 5
  rules:
    - name: React to the event
      condition: event.message == "hello from a rulebook"
      action:
        debug:
          msg: "Rulebook fired - this ran in a decision environment"
```

**`payload`, singular.** `payloads` is the natural guess and the plugin rejects it with `Args.__init__() missing 1 required positional argument: 'payload'` — from inside the DE container, which by then has already started and connected.

Commit it, push into a bare repo under `~/ace/eda/git/`, and serve that directory with the git-server container.

## Activations

Three things have to be right before an activation will even be created.

**1. Seed EDA's initial data.** Creating an activation validates credentials against `CredentialType` rows that a fresh database does not have, and the API returns a bare `Unexpected server error`. The traceback says `DoesNotExist: CredentialType matching query does not exist`:

```bash
podman exec ace-eda-api aap-eda-manage create_initial_data
```

That creates 28 credential types and the platform's role definitions.

**2. The podman socket.** Activations start DE containers through podman's **API socket**, not the CLI:

```bash
systemctl --user enable --now podman.socket
```

```yaml
PODMAN_SOCKET_URL: 'unix:///run/podman/podman.sock'
```

with the host socket mounted into the activation worker. Note what this is *not*: unlike [Lab 7](07-execution.md), nothing here runs podman inside a container. The worker is an API **client** of the host's podman, which is why this needs none of Lab 7's capabilities, devices or storage gymnastics.

**3. The DE's pull policy.** The image was built locally and exists in the host's store, but EDA still tries to pull it — and `localhost/...` sends podman to a registry called `localhost`, which refuses the connection. The activation fails with a 500 whose body is just `{"message":"connection refused"}`:

```bash
curl ... -X PATCH "$B/decision-environments/1/" -d '{"pull_policy":"never"}'
```

**Lowercase.** `"Never"` is rejected with `"Never" is not a valid choice.` — the enum values are `always`, `never`, `missing`.

### The CA, one more time

With all that, the DE container starts, connects back to EDA's websocket, and dies:

```
ansible_rulebook.websocket - WARNING - websocket aborted by OSError:
  [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed
```

A DE is a container **EDA** starts, not one you wrote a quadlet for, so nothing has mounted the platform CA into it. `PODMAN_MOUNTS` is how you reach containers you do not launch yourself:

```yaml
PODMAN_MOUNTS: '@json [{"source": "/home/jamie/ace/tls/extracted",
                        "target": "/etc/pki/ca-trust/extracted",
                        "type": "bind", "read_only": true, "relabel": "shared"}]'
```

This is the fourth distinct place the CA has had to be plumbed — the extracted bundle in [Lab 3](03-internal-ca.md), `REQUESTS_CA_BUNDLE` for Python in [Lab 7](07-execution.md), the read-only bind into execution environments, and now this. One CA, four mechanisms, because four different things start containers.

### Run it

```bash
post decision-environments '{"name":"ACE DE","image_url":"localhost/ace-de-supported:dev","organization_id":1}'
post projects '{"name":"ACE rulebooks","url":"git://127.0.0.1/ace-rulebooks.git","organization_id":1}'
post activations '{"name":"ACE hello activation","project_id":1,"rulebook_id":1,
                   "decision_environment_id":1,"organization_id":1,
                   "is_enabled":true,"restart_policy":"never"}'
```

**Want:** the activation moving `starting` → `running` → `completed`, and in its instance logs:

```
Container args ['ansible-rulebook', '--worker', '--websocket-url',
  'wss://ace-eda:8445/api/eda/ws/ansible-rulebook', ...]
Container ... is running.
[debug] ******************************************
Rulebook fired - this ran in a decision environment
Container ... is cleaned up.
```

Read what that took. EDA cloned a rulebook from a git daemon, asked the host's podman API for a decision-environment container you built, handed it a websocket URL and a token, and the DE connected *back* to EDA over TLS it could verify — then ran the rule and shut down. The event loop closed inside a container that did not exist thirty seconds earlier.

## What you have now

Five components, all built from upstream source, all behind one login:

```bash
curl -u "$A" --cacert $C https://ace-gateway/api/controller/v2/ping/
curl -u "$A" --cacert $C https://ace-gateway/api/galaxy/pulp/api/v3/status/
curl -u "$A" --cacert $C https://ace-gateway/api/eda/v1/status/
curl http://127.0.0.1:9901/clusters | grep health_flags
```

**Want:** three services answering, and four `healthy` clusters in envoy.

Open `https://ace-gateway/` and log in. Automation Execution, Automation Content and Automation Decisions are all in the sidebar — because the registry has four services in it, and the navigation is assembled from the registry at page load.

— [Cleanup](99-cleanup.md) · [Glossary](glossary.md)
