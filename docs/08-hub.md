# Lab 8 — Automation hub

## What you will have at the end

galaxy_ng on pulpcore, built from source, running as four containers and registered with the gateway.

## Where it fits

By now the shape is familiar — build an image, write configs, write quadlets, register four API objects. Hub's contribution is a different lesson: **what to do when a project's own dependency pins do not install.**

## The Containerfile

The base is `docker.io/pulp/base`, which is pulp's own multi-arch image, and galaxy_ng comes from its upstream repo at a pinned ref.

**Why built rather than pulled:** `quay.io/ansible/galaxy-ng` is amd64-only and `pulp/pulp-galaxy-ng` is abandoned.

### Check which branch you are on before you debug anything

galaxy_ng has **two** long-lived branches, and only one of them is current:

| Branch | Declares | Pins |
|---|---|---|
| `master` | 4.11.0dev | pulpcore 3.49.40, Django 4.2 |
| **`main`** (default) | **4.12.0dev** | **pulpcore 3.105.12, Django 5.2** |

`master` is stale. Its lockfile no longer resolves against current PyPI — it pins `pulpcore==3.49.40` next to `aiohttp` and `protobuf` versions that pulpcore's published metadata forbids — and pip's error tells you about aiohttp, then protobuf, then the next one, forever. Nothing about the message suggests the branch is the problem.

Build from `main`. The vendor ships galaxy-ng 4.12.2 on pulpcore 3.105.12; `main` gives 4.12.0dev on pulpcore 3.105.12, which is the same platform.

> This is worth internalising beyond hub: **a default branch is not always the one you first find.** Check `git ls-remote --symref <repo> HEAD` before pinning anything.

### The lockfile, used properly

Even on `main`, asking pip to resolve galaxy_ng's `setup.py` unaided sends it backtracking — the declared ranges are loose and the search space is large. galaxy_ng ships its own pip-compile lockfile, so use it as constraints:

```dockerfile
ADD https://raw.githubusercontent.com/ansible/galaxy_ng/${GALAXY_NG_REF}/requirements/requirements.common.txt /tmp/galaxy-lock.txt
RUN sed -E 's/\[[^]]*\]//' /tmp/galaxy-lock.txt | grep -v '@ git+' > /tmp/galaxy-constraints.txt
RUN pip3 install --no-cache-dir -c /tmp/galaxy-constraints.txt \
      "galaxy-ng @ https://github.com/ansible/galaxy_ng/archive/${GALAXY_NG_REF}.tar.gz"
```

Two things have to come out of the lockfile first:

- **Extras.** pip refuses a constraints file whose entries carry them — `Constraints cannot have extras` — and a pip-compile lockfile is full of `package[extra]==version`. The version pin is the point; the extras are not.
- **Direct git references.** A constraint must be a name and a version specifier, and the lockfile pins django-ansible-base to a git ref. That is also the one dependency deliberately overridden below, so dropping it here is exactly right.

**Why DAB is overridden:** galaxy_ng pins django-ansible-base to a *specific commit* in its `setup.py`. The gateway builds against DAB `devel`. When those two drift apart the JWT format drifts with them, and hub starts rejecting tokens the gateway signed — classically with `Token is missing the "objects" claim`. Forcing DAB to `devel` here makes hub's copy exactly the gateway's.

### The DAB generation check

This is the first thing to run when single sign-on misbehaves anywhere in the platform — every service that sits behind the gateway consumes its JWT through DAB, so they all have to agree:

```bash
podman run --rm --entrypoint "" localhost/ace-gateway:dev \
  /opt/aap_gateway/venv/bin/pip show django-ansible-base | awk '/^Version/{print}'
podman run --rm --entrypoint "" localhost/ace-hub:dev \
  pip3 show django-ansible-base | awk '/^Version/{print}'
podman run --rm --entrypoint "" localhost/ace-controller:dev \
  /var/lib/awx/venv/awx/bin/pip show django-ansible-base | awk '/^Version/{print}'
podman run --rm --entrypoint "" localhost/ace-eda:dev \
  /app/venv/bin/pip show django-ansible-base | awk '/^Version/{print}'
```

**Want:** the same *generation* everywhere. On this build the gateway, hub and controller land on the identical devel build, and EDA trails by a few weeks because its version comes from `poetry.lock` rather than an override — which is fine. A few weeks of devel is not the problem; a *stable* branch pinning a DAB from a different era is, and that is what breaks SSO.

[Lab 9](09-eda.md) shows how to confirm SSO actually works rather than inferring it from version numbers.

## Key material and configuration

Hub needs more than a certificate:

```bash
mkdir -p ~/ace/hub/keys
~/ace/tls/ace-cert pulp_webserver hub ace-hub crt

cd ~/ace/hub
openssl rand -base64 32 | tr -d '\n' > keys/database_fields.symmetric.key
openssl ecparam -name prime256v1 -genkey -noout -out keys/container_auth_private_key.pem
openssl ec -in keys/container_auth_private_key.pem -pubout -out keys/container_auth_public_key.pem
chmod 0640 keys/*
```

The symmetric key encrypts credentials in pulp's database; the EC pair signs container-registry tokens (`TOKEN_SIGNATURE_ALGORITHM = 'ES256'`).

In `settings.py`, every externally-visible URL is the **front door**, not hub's own nginx — hub builds the URLs it hands to clients from these:

```python
CONTENT_ORIGIN = 'https://ace-gateway'
ANSIBLE_API_HOSTNAME = 'https://ace-gateway'
ANSIBLE_CONTENT_HOSTNAME = 'https://ace-gateway'
ANSIBLE_BASE_JWT_KEY = 'https://ace-gateway'
RESOURCE_SERVER__URL = 'https://ace-gateway'
```

`GALAXY_AUTO_SIGN_COLLECTIONS` is **off** here. The vendor turns it on and points it at a GPG signing service we have not built.

## Migrations and the quadlets

```bash
podman run --rm --network host --userns keep-id:uid=1000,gid=0 \
  -v ~/ace/hub/settings.py:/etc/pulp/settings.py:ro,Z \
  -v ~/ace/hub/keys:/etc/pulp/keys:ro,Z \
  -v ~/ace/redis/run:/run/redis:Z \
  -v ~/ace/tls/extracted:/etc/pki/ca-trust/extracted:z \
  -e PULP_SETTINGS=/etc/pulp/settings.py \
  --entrypoint "" localhost/ace-hub:dev pulpcore-manager migrate --noinput
```

Four containers off one image, plus nginx:

| Unit | Process | Port |
|---|---|---|
| `ace-hub-api` | `pulpcore-api` | 24817 |
| `ace-hub-content` | `pulpcore-content` | 24816 |
| `ace-hub-worker` | `pulpcore-worker` | — |
| `ace-hub-web` | nginx | 8444 |

Generate the service key from the gateway and pass it as `PULP_RESOURCE_SERVER__SECRET_KEY`, exactly as [Lab 7](07-execution.md) did for the controller.

> **The nginx containers do not use `keep-id`.** nginx wants to be root inside its own namespace so it can create `/var/cache/nginx/client_temp` and then drop privileges itself. Under `keep-id` it runs as you and fails at startup with `mkdir() "/var/cache/nginx/client_temp" failed (13: Permission denied)` — a permission error about a path you never configured. The certificates are mounted read-only and appear root-owned inside, which is exactly what nginx wants.

## Registration and verify

```bash
post service_clusters '{"name":"hub","service_type":3}'
post service_nodes    '{"name":"Node hub - ace-hub","service_cluster":4,"address":"ace-hub"}'
post services         '{"name":"galaxy api","api_slug":"galaxy","http_port":1,"service_cluster":4,
                        "is_service_https":true,"service_path":"/api/galaxy/","service_port":8444,"order":2}'
```

```bash
curl -u "$A" --cacert $C https://ace-gateway/api/galaxy/pulp/api/v3/status/
```

**Want:** a version list naming `pulpcore`, `pulp_ansible` and `pulp_container`.

> **If you get `no healthy upstream`, restart envoy.** The gateway gives each service type a `ping_url` and envoy health-checks it. A check that failed while the service was still starting is remembered, and the endpoint stays `failed_active_hc` until envoy re-runs it. `curl http://127.0.0.1:9901/clusters | grep health_flags` shows the truth; `systemctl --user restart ace-envoy` clears it.

Next: [Event-Driven Ansible](09-eda.md)
