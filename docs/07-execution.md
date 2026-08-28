# Lab 7 — Execution: receptor and podman

> **Partially complete.** Everything through the mesh works and is verified. The last step — a job actually executing in an EE container — is blocked on nested rootless podman, characterised precisely at the end of this lab. Read that section before starting.

## What you will have at the end

receptor built from source and running as its own container, a mesh the controller can drive, work signing you set up yourself, and an execution environment you built.

## Where it fits

[Lab 6](06-controller.md) already borrowed half of this lab: the AWX dispatcher refuses to start without `/etc/receptor/receptor.conf`, so the work-signing keypair and the config were created there. What is left here is running receptor as a service, building the EE, and getting work to flow.

**Build this lab's receptor image before Lab 6**, because AWX's image copies the receptor binary in from it.

## The receptor image

```bash
cd containerfiles/receptor
podman build -t localhost/ace-receptor:dev .
```

A Go build and a small runtime — the simplest Containerfile in the tutorial, running the hardest lab. Two things in it are not obvious:

- **ansible-runner is installed here**, not just in the EE. receptor's `work-command` is literally `ansible-runner worker`; receptor is the *parent* of the job, so the runner has to exist in receptor's own filesystem.
- **podman is installed here rather than mounted from the host.** The vendor's installer mounts a host binary into the container, which only works if the container carries the libraries that binary was linked against. Mount your host's `/usr/bin/podman` straight in and it dies at exec:

  ```
  podman: error while loading shared libraries: libsubid.so.6:
  cannot open shared object file: No such file or directory
  ```

  and receptor reports that not as a missing binary but as `Exceeded retries for reading stdout` — because from receptor's side, the work command simply produced nothing.

## The execution environment

```bash
cd containerfiles/ee-minimal
podman build -t localhost/ace-ee-minimal:dev .
```

An EE is not magic: a base image, ansible-core, ansible-runner, and a writable `/runner` where ansible-runner stages each job's private data directory. `ansible-builder` exists to generate a Containerfile like this from an `execution-environment.yml`; we write it, because a generated file you never read teaches nothing.

## receptor as a service

The config was written in [Lab 6](06-controller.md). Two things about it matter here.

**The node id must match the controller's `CLUSTER_HOST_ID`.** Left unset, receptor uses the machine's hostname — so on this box the mesh came up as node `oz` while AWX was looking for `ace-controller`, and nothing connected them. Set it explicitly.

**Give it a `datadir`.** Unset, receptor keeps work units in `/tmp/receptor`, inside the container, and a work unit whose status file vanishes mid-run fails with `Exceeded retries for reading stdout` — which says nothing about storage.

```bash
vim ~/.config/containers/systemd/ace-receptor.container
systemctl --user daemon-reload
systemctl --user start ace-receptor
```

The control socket lives on a host path (`~/ace/receptor/run`) mounted into **both** receptor and the controller's task container. That socket is the entire interface between the control plane and the execution plane.

> **receptor needs both halves of the signing keypair.** The controller signs work units with the private key and receptor verifies with the public one — but receptor reads the same `receptor.conf`, which names both, and refuses to start if the private key is missing. On a multi-node mesh the signing node and the verifying node are different machines with different halves; here they are one node holding both.

## Verify the mesh

```bash
podman exec ace-awx-task receptorctl --socket /var/run/receptor/receptor.sock status
```

**Want:**

```
Node ID: ace-controller
ace-controller  control  Stream  ...  {'type': 'Control Service'}
Node            Secure Work Types
ace-controller  local
```

`Secure Work Types: local` is work signing confirming itself: receptor will only run a `local` work unit that carries a valid signature.

The `receptorctl and receptor are different versions` warning is expected — receptorctl comes from PyPI and receptor from a pinned git tag.

## What the controller needs before a job can run

Three things that are easy to miss, each of which produces a job stuck or failing in a way that points elsewhere.

**Instance groups.** A fresh AWX has an instance with capacity and *no instance groups*, so every job sits in `pending` forever with nothing in any log:

```bash
podman exec ace-awx-task awx-manage register_queue --queuename=default --hostnames=ace-controller
podman exec ace-awx-task awx-manage register_queue --queuename=controlplane --hostnames=ace-controller
```

**The job execution directory.** `AWX_ISOLATION_BASE_PATH` points at `/var/lib/awx/job_execution`, which the image does not create. Without it the job errors instantly with `FileNotFoundError: /var/lib/awx/job_execution/awx_2_...`. It is created on the host and mounted into the controller — and into **receptor**, at the same path, because the controller hands ansible-runner a private-data-dir path from its own layout and receptor is the process that has to create it.

**The gateway's service data migration.** See below — it blocks more than jobs.

## `migrate_service_data`, and the two failures behind it

Any attempt to sync resources — or even to create an organization in AWX — fails with:

```
423 Client Error: Locked for url: https://ace-gateway:9443/api/gateway/v1/service-index/metadata/
```

The gateway refuses *all* service-token authentication until its data migration has run:

```python
status_code = 423
default_detail = 'Service authentication is locked until migrate_service_data is complete.'
```

```bash
podman exec ace-gateway aap-gateway-manage migrate_service_data --username admin
```

Which then fails on something else entirely:

```
CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate
```

**Mounting the extracted trust bundle is not enough for Python.** [Lab 3](03-internal-ca.md)'s bundle at `/etc/pki/ca-trust/extracted` is read by OpenSSL-linked C code; Python's `requests` uses `certifi`'s bundle instead and never looks at it. Both the gateway and the controller need to be told:

```ini
Environment=REQUESTS_CA_BUNDLE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
Environment=SSL_CERT_FILE=/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem
```

This is worth understanding rather than pasting: everything in the platform validated certificates correctly *until* a Python process made an outbound HTTPS call to another platform component. Then, and only then, the trust store stopped applying.

With that fixed, the migration succeeds and the lock lifts:

```bash
podman exec ace-awx-task awx-manage resource_sync
```

**Want:** the gateway's `Default` organization appearing in the controller. That is the resource registry working — one identity, one org list, two databases.

## Where this stops: nested rootless podman

receptor starts the job by calling `podman run` **inside its own container**, which is rootless podman inside rootless podman. Two walls, in order:

**The image store cannot simply be shared.** podman records the absolute path of its storage in its own database, so mounting the host's store at a different path inside the container fails with `database configuration mismatch`, and mounting it at the *same* path requires `HOME` to match and the mount parents to be owned by the running user — podman refuses a config directory it does not own. Even when all of that lines up, two podmen writing one store is a lock race waiting to happen.

Giving the inner podman its **own** store and delivering the EE image into it (`podman save` on the host, `podman load` inside) is the cleaner design, and it is what this lab does. That is where the real wall is:

```
potentially insufficient UIDs or GIDs available in user namespace
(requested 0:12 for /var/spool/mail): Check /etc/subuid and /etc/subgid
```

Unpacking an image whose layers contain files owned by several different UIDs needs the unpacking podman to *have* several UIDs. `UserNS=keep-id` maps exactly one — yours — so the inner podman has a single UID and cannot represent the layer.

The fix is to give the receptor container a **range** of UIDs (`UserNS=auto`), and that collides with the rest of the design: the control socket at `~/ace/receptor/run/receptor.sock` has to be openable by the controller's task container, which runs `keep-id` as you. Under `auto`, receptor creates that socket as a subordinate UID that the controller cannot open.

So the two halves want opposite user-namespace mappings, and reconciling them is the open problem in this lab. Options not yet tried here, in rough order of promise:

- `UserNS=auto` on receptor plus an explicit `--uidmap` entry that keeps your own UID mapped, so the socket stays yours while a range exists for image unpacking
- a shared group on the socket directory, with receptor under `auto` and the socket mode widened to `0660` with a gid both containers map
- running receptor as a **host** process rather than a container — the vendor's own bare-metal topology does exactly this, and it is worth asking whether the execution plane is the one component that should not be containerized on a single-host build

None of these is a guess to write into the lab before it is tried. This section will say what worked once one of them does.

## What is verified

- receptor built from source, running, control socket shared with the controller
- node id matching `CLUSTER_HOST_ID`, work signing active (`Secure Work Types: local`)
- the EE image built from source
- instance groups registered, instance at capacity 136
- `migrate_service_data` complete, resource sync working, the gateway's org visible in the controller
- a job reaching `running` and receptor invoking `ansible-runner` — the control plane and mesh are correct

## What is not

- a job completing. It fails inside the EE step, at image unpack, for the user-namespace reason above.

Next: [Automation hub](08-hub.md)
