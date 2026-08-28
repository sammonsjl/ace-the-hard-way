# Lab 7 — Execution: receptor and podman

## What you will have at the end

receptor built from source and running as its own container, work signing you set up yourself, an execution environment you built — and a playbook that actually runs, in a container, started by a container.

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
podman exec ace-awx-task /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/receptor/receptor.sock status
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

**The job execution directory.** `AWX_ISOLATION_BASE_PATH` points at `/var/lib/ansible-automation-platform/controller/data/job_execution`, which the image does not create. Without it the job errors instantly with `FileNotFoundError: .../job_execution/awx_2_...`. It is created on the host and mounted into the controller — and into **receptor**, at the same path, because the controller hands ansible-runner a private-data-dir path from its own layout and receptor is the process that has to create it.

**The gateway's service data migration.** See below — it blocks more than jobs.

## `migrate_service_data`, and the two failures behind it

Any attempt to sync resources — or even to create an organization in AWX — fails with:

```
423 Client Error: Locked for url: https://ace-gateway/api/gateway/v1/service-index/metadata/
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

## Nested rootless podman

receptor starts each job by calling `podman run` **inside its own container** — rootless podman inside rootless podman. This is the hardest part of the tutorial and it fails in five distinct ways, each with an error that names something other than the cause. They are worth working through in order, because every one of them teaches something about user namespaces.

### 1. The image store cannot be shared with the host

podman records the *absolute path* of its storage in its own database, so mounting the host's store at a different path inside the container fails with `database configuration mismatch`. Mounting it at the same path then requires `HOME` to match and every mount parent to be owned by the running user, because podman refuses a config directory it does not own. And even with all of that aligned, two podmen writing one store is a lock race.

Give the inner podman its **own** store and deliver the EE into it:

```bash
podman save -o ~/ace/receptor/images/ace-ee-minimal.tar localhost/ace-ee-minimal:dev
podman exec ace-receptor podman load -i /images/ace-ee-minimal.tar
```

### 2. One UID is not enough to unpack an image

```
potentially insufficient UIDs or GIDs available in user namespace
(requested 0:12 for /var/spool/mail)
```

Layers contain files owned by several users; unpacking them needs several UIDs. `UserNS=keep-id` maps exactly one — and it has to, because the control socket receptor creates must be openable by the controller's task container running as you. Giving receptor a UID range with `UserNS=auto` would fix the unpack and break the socket.

There is a second half to this, in the image rather than the config. `useradd` hands every new user a subuid/subgid range, and the inner podman finds it and tries to use it:

```
newuidmap: write to uid_map failed: Operation not permitted
Error: cannot set up namespace using "/usr/bin/newuidmap"
```

It cannot: `newuidmap` is not setuid inside the container, and the outer namespace has one UID mapped anyway. So the receptor image empties `/etc/subuid` and `/etc/subgid` — take the ranges away and podman stops trying, falling back to the single-UID mode this whole section is about.

The way out is not more UIDs but fewer expectations. `~/ace/receptor/containers-conf/storage.conf`:

```ini
[storage.options.overlay]
ignore_chown_errors = "true"
```

The inner podman then unpacks the layer anyway and lets every file belong to the one UID it has. **State the cost plainly:** ownership inside execution environments is flattened. For running playbooks that is irrelevant; for an image that depends on multi-user ownership at runtime it would not be.

### 3. Devices

```
fuse: device not found, try 'modprobe fuse' first
Failed to open() /dev/net/tun
```

The inner podman performs a real fuse-overlayfs mount and builds a real network namespace, so it needs the devices to do both:

```ini
AddDevice=/dev/fuse
AddDevice=/dev/net/tun
```

### 4. Capabilities and masked paths

```
crun: mount `proc` to `proc`: Operation not permitted
```

A nested container mounts its own `/proc`. That needs `SYS_ADMIN`, an unconfined seccomp profile — and `Unmask=ALL`, because podman masks paths under `/proc` in every container it starts and the inner runtime has to mount over them.

```ini
AddCapability=SYS_ADMIN
AddCapability=SYS_CHROOT
AddCapability=MKNOD
AddCapability=SETFCAP
SeccompProfile=unconfined
SecurityLabelDisable=true
Unmask=ALL
```

This is the point in the tutorial where the security posture is loosest, and it should be uncomfortable. A container that can mount filesystems and has an unconfined seccomp profile is close to not being a boundary. On the vendor's own topology the execution plane is a **separate machine** for exactly this reason — the isolation is the VM, not the container.

### 5. Two settings on the controller side

The EE cannot build a network namespace either — the nested podman cannot write `/proc/sys/net/ipv4/ping_group_range`. Every service here is already on the host network, so give the EE the host network too:

```python
DEFAULT_CONTAINER_RUN_OPTIONS = ["--network", "host"]
```

And AWX's production defaults mount the CA paths into every EE as *ephemeral overlays*:

```python
AWX_ISOLATION_SHOW_PATHS = [
    '/etc/pki/ca-trust:/etc/pki/ca-trust:O',
    '/usr/share/pki:/usr/share/pki:O',
]
```

An overlay mount has to chown its upper directory, and we are back to one UID:

```
mounting overlay failed "/usr/share/pki": chown .../upper: invalid argument
```

A read-only bind gives the EE the same trust store with no upper directory to own — and `/etc/pki/ca-trust` inside the receptor container is already the extracted bundle from [Lab 3](03-internal-ca.md), so the EE inherits the platform CA:

```python
AWX_ISOLATION_SHOW_PATHS = ['/etc/pki/ca-trust:/etc/pki/ca-trust:ro']
```

> The `cannot find UID/GID for user jamie: no subuid ranges found` line at the top of every job's output is expected and harmless. The inner podman is reporting that it has a single mapping — which is exactly the arrangement `ignore_chown_errors` exists to accommodate.

## Run a job

Create an inventory with `localhost` and `ansible_connection: local`, a project, and a job template using the EE. Then launch it and watch the output.

**Want:**

```
PLAY [ACE smoke test] **********************************************************

TASK [Say hello from inside an execution environment] **************************
ok: [localhost] => {
    "msg": "Hello from localhost - this ran in a container started by receptor"
}

PLAY RECAP *********************************************************************
localhost                  : ok=1    changed=0    unreachable=0    failed=0
```

Follow what that took. The request arrived at envoy on 443 and was authorised over gRPC by the gateway. The controller's dispatcher accepted the job, signed a work unit, and handed it to receptor over a unix socket. receptor verified the signature, ran `ansible-runner worker`, and ansible-runner started an execution environment — a container, started by a container, on a machine where nothing runs as root.

Next: [Automation hub](08-hub.md)
