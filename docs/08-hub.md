# Lab 8 — Automation hub

## What you will have at the end

galaxy_ng on pulpcore, built from source, running as four containers and registered with the gateway.

## Where it fits

By now the shape is familiar — build an image, write configs, write quadlets, register four API objects. Hub's contribution is a different lesson: **what to do when a project's own dependency pins do not install.**

## The Containerfile

The base is `docker.io/pulp/base`, which is pulp's own multi-arch image, and galaxy_ng comes from its upstream repo at a pinned ref.

**Why built rather than pulled:** `quay.io/ansible/galaxy-ng` is amd64-only and `pulp/pulp-galaxy-ng` is abandoned.

### The dependency problem, and the four things that do not fix it

Ask pip to install galaxy_ng and let it resolve, and it does not fail — it *backtracks*, downloading metadata for the same handful of packages over and over, for as long as you let it. galaxy_ng's `setup.py` declares loose ranges and the search space is enormous.

galaxy_ng ships a pip-compile lockfile at `requirements/requirements.common.txt`, so the obvious move is to use it. Four attempts, in order, and what each taught:

| Attempt | Result |
|---|---|
| Lockfile as `--constraint` | `ERROR: Constraints cannot have extras` — a pip-compile lockfile is full of `package[extra]==version`, and constraints may not carry extras |
| Strip the extras | `ResolutionImpossible` — the lockfile pins django-ansible-base to a **git ref**, which is not a valid constraint and contradicts our DAB override |
| Drop git refs too | `pulpcore 3.49.40 depends on aiohttp<3.10.12; the user requested aiohttp==3.12.14` |
| Drop `aiohttp` as well | the same failure again, for `protobuf` — and it would keep going |

That last pair is the actual finding: **the lockfile is stale against PyPI.** It pins `pulpcore==3.49.40` alongside aiohttp and protobuf versions that pulpcore's *published metadata* forbids. Whatever generated it did not enforce those ranges. No amount of excluding one package at a time converges, because every resolution reads that metadata.

### What does work

Install the pinned set as a **requirements file with `--no-deps`**:

```dockerfile
RUN sed -E 's/\[[^]]*\]//' /tmp/galaxy-lock.txt | grep -v '@ git+' > /tmp/galaxy-pins.txt && \
    pip3 install --no-cache-dir --no-deps -r /tmp/galaxy-pins.txt
```

pip-compile already produced a complete closure — every transitive dependency is in the file with an exact version. There is nothing to resolve, so `--no-deps` skips the resolver *and* the metadata checks that were failing. galaxy_ng then goes on top, also `--no-deps`, because everything it wants is already installed.

> **`--no-deps` is not a way to silence a real conflict.** It is correct here for one specific reason: the input is a complete, pre-resolved closure. Using it on an ordinary `pip install` would hide genuine breakage.

### One more, after that

```
ImportError: cannot import name 'get_storage_class' from 'django.core.files.storage'
```

The DAB-devel install — the one that has to override the lockfile so hub's JWT dialect matches the gateway's — pulled Django 5.2 in as a dependency, clobbering the pinned 4.2. pulpcore 3.49.40 uses an API Django removed. So that install needs `--no-deps` too:

```dockerfile
RUN pip3 install --no-cache-dir --no-deps --upgrade \
      "django-ansible-base[feature-flags,jwt-consumer] @ git+https://github.com/ansible/django-ansible-base@devel"
```

**Why DAB is overridden at all:** the gateway builds against DAB devel, whose JWTs no longer carry a claim that galaxy_ng's own pin still expects. Leave it and hub rejects every token the gateway signs.

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
CONTENT_ORIGIN = 'https://ace-gateway:9443'
ANSIBLE_API_HOSTNAME = 'https://ace-gateway:9443'
ANSIBLE_CONTENT_HOSTNAME = 'https://ace-gateway:9443'
ANSIBLE_BASE_JWT_KEY = 'https://ace-gateway:9443'
RESOURCE_SERVER__URL = 'https://ace-gateway:9443'
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
curl -u "$A" --cacert $C https://ace-gateway:9443/api/galaxy/pulp/api/v3/status/
```

**Want:** a version list naming `pulpcore`, `pulp_ansible` and `pulp_container`.

> **If you get `no healthy upstream`, restart envoy.** The gateway gives each service type a `ping_url` and envoy health-checks it. A check that failed while the service was still starting is remembered, and the endpoint stays `failed_active_hc` until envoy re-runs it. `curl http://127.0.0.1:9901/clusters | grep health_flags` shows the truth; `systemctl --user restart ace-envoy` clears it.

Next: [Event-Driven Ansible](09-eda.md)
