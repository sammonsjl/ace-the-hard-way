# Lab 7 — Execution: the receptor mesh

## What this is

Two machines. `ace-controller` schedules work and signs it; `ace-exec` receives it over a
mutually-authenticated TCP mesh and runs it in a container. This is the lab where the platform
stops being able only to *accept* a job and starts being able to *run* one.

## Where it fits

Lab 6 left you a control node that registers, browses, and dispatches into an empty queue. Nothing
consumes that queue yet. This lab builds the consumer, and the wire between them.

## Why it is two machines

- A **control** node schedules jobs and runs control-plane work — project updates, inventory syncs.
- An **execution** node runs user jobs and nothing else.
- A **hybrid** node does both, and hides the wire.

Splitting them is how execution scales independently of the control plane, and it is the only
arrangement where the mesh is visible: a listener, a peer, and a second CA whose certificates carry
the receptor node ID in a custom X.509 extension.

## What you will have at the end

Receptor running on both nodes, peered over TLS on 27199; `ace-exec` registered with AWX in the
`default` queue; and a job whose `controller_node` and `execution_node` are two different hosts.

---

## 1. Receptor, on both nodes

Run everything in this section **on `ace-controller` and on `ace-exec`**.

```bash
RECEPTOR_VERSION=1.6.5
ARCH=$(uname -m); case $ARCH in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
curl -fsSL -o /tmp/receptor.tgz \
  "https://github.com/ansible/receptor/releases/download/v${RECEPTOR_VERSION}/receptor_${RECEPTOR_VERSION}_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/receptor.tgz -C /usr/local/bin receptor
/usr/local/bin/receptor --version
```

`ace-exec` has no AWX, so it has no `awx` user yet. Create one there — the mesh runs as the same
service user on both ends:

```bash
# ace-exec only
sudo useradd --system --create-home --home-dir /var/lib/awx --shell /bin/bash awx
```

Directories, on both. The datadir must be writable and **not** on tmpfs — work units have to
survive a restart:

```bash
sudo install -d -o awx -g awx -m 0750 /etc/receptor
sudo install -d -o awx -g awx -m 0750 /etc/receptor/certs
sudo install -d -o awx -g awx -m 0700 /var/lib/receptor

sudo tee /etc/tmpfiles.d/awx-receptor.conf >/dev/null <<'EOF'
D /run/awx-receptor 0750 awx awx -
EOF
sudo tee /etc/tmpfiles.d/receptor.conf >/dev/null <<'EOF'
D /run/receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/awx-receptor.conf /etc/tmpfiles.d/receptor.conf

df --output=fstype /var/lib/receptor | tail -1

sudo tee /etc/security/limits.d/awx.conf >/dev/null <<'EOF'
# AWX limits
awx soft nofile 4096
awx hard nofile 8192
EOF
```

> **Left unset, the datadir falls back to `/tmp/receptor`, which is swept.** `/run/receptor` is
> receptor's own default and `/run/awx-receptor` is where the control socket goes; a packaged
> install creates both, so both are here.

---

## 2. The mesh CA

Run this **on `ace-controller`**.

Receptor authenticates a peer by the **node ID inside its certificate**, carried in a private
extension (OID `1.3.6.1.4.1.2312.19.1`) that `openssl req` will not produce on its own. So the mesh
CA is built with receptor's own tooling, and it is a different CA from [Lab 3](03-internal-ca.md)'s
— a compromised web certificate must never be able to mint a mesh node.

```bash
sudo -u awx /usr/local/bin/receptor --cert-init \
  commonname="ACE mesh CA" bits=4096 \
  outcert=/etc/receptor/certs/mesh-ca.crt outkey=/etc/receptor/certs/mesh-ca.key
sudo chmod 0600 /etc/receptor/certs/mesh-ca.key
```

One certificate per node, each stamped with its own node ID:

```bash
for NODE in ace-controller ace-exec; do
  sudo -u awx /usr/local/bin/receptor --cert-makereq \
    bits=4096 commonname="$NODE" dnsname="$NODE" nodeid="$NODE" \
    outreq=/etc/receptor/certs/$NODE.req outkey=/etc/receptor/certs/$NODE.key
  sudo -u awx /usr/local/bin/receptor --cert-signreq \
    req=/etc/receptor/certs/$NODE.req \
    cacert=/etc/receptor/certs/mesh-ca.crt cakey=/etc/receptor/certs/mesh-ca.key \
    outcert=/etc/receptor/certs/$NODE.crt verify=true
done
sudo chmod 0600 /etc/receptor/certs/*.key
```

> **`verify=true` means "do not prompt", which is the opposite of how it reads.** Without it
> `--cert-signreq` stops at `Sign certificate (yes/no)?` and waits on stdin. Interactively that is
> merely a keystroke; in a script it is worse than a hang, because the prompt eats the *next line of
> the script* as its answer — you get `Error: expected newline` followed by whatever fragment
> survived, such as `bash: line 10: 600: command not found` from a half-consumed `chmod 0600`.


Confirm the node ID actually landed in the certificate — this is the field the peer checks:

```bash
openssl x509 -in /etc/receptor/certs/ace-exec.crt -noout -text | grep -A3 'Subject Alternative Name'
```

You are looking for `othername` with that OID, not just the DNS name.

### Work-signing keys

The controller signs every work unit; the execution node refuses anything it cannot verify. Two
keys, one direction:

```bash
sudo -u awx openssl genrsa -out /etc/receptor/work_private_key.pem 4096
sudo -u awx openssl rsa -in /etc/receptor/work_private_key.pem \
  -pubout -out /etc/receptor/work_public_key.pem
sudo chmod 0600 /etc/receptor/work_private_key.pem
sudo chmod 0644 /etc/receptor/work_public_key.pem
```

### Hand the execution node its half

`/srv/ace` is the NFS share from [Lab 2](02-vms.md). The private CA key and the controller's own
key never travel:

```bash
sudo install -d -m 0750 /srv/ace/mesh
sudo cp /etc/receptor/certs/mesh-ca.crt \
        /etc/receptor/certs/ace-exec.crt \
        /etc/receptor/certs/ace-exec.key \
        /etc/receptor/work_public_key.pem /srv/ace/mesh/
```

> **Root, not `awx`, on both ends of the share** — the same convention
> [Lab 3](03-internal-ca.md) uses. `/srv/ace` is `root:root 0755` and the export carries
> `no_root_squash`, so root can write across it and the service user cannot:
> `sudo -u awx install -d /srv/ace/mesh` fails with a bare `Permission denied` that looks like an
> NFS problem and is not one.

On **`ace-exec`**:

```bash
sudo cp /srv/ace/mesh/mesh-ca.crt /srv/ace/mesh/ace-exec.crt \
        /srv/ace/mesh/ace-exec.key /etc/receptor/certs/
sudo cp /srv/ace/mesh/work_public_key.pem /etc/receptor/
sudo chown awx:awx /etc/receptor/certs/mesh-ca.crt /etc/receptor/certs/ace-exec.crt \
                   /etc/receptor/certs/ace-exec.key /etc/receptor/work_public_key.pem
sudo chmod 0600 /etc/receptor/certs/ace-exec.key
sudo chmod 0644 /etc/receptor/work_public_key.pem
```

Then, back on the controller, take the courier copy away — it has served its purpose:

```bash
sudo rm -rf /srv/ace/mesh
```

---

## 3. `ace-exec`: podman, ansible-runner, receptor

### podman

An execution environment **is** a container image. AWX has had no containerless execution since
version 18, so the node that runs work needs a container runtime. Nothing you *build* runs in a
container; the runtime is the job sandbox.

```bash
sudo dnf -y install podman crun slirp4netns
grep -q ^awx: /etc/subuid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 awx
sudo loginctl enable-linger awx
loginctl show-user awx --property=Linger
```

### ansible-runner

The control node gets `ansible-runner` inside the AWX venv. This node has no AWX, so it needs its
own — this is the one piece an execution node installs that a hybrid node gets for free:

```bash
sudo dnf -y install python3 python3-pip
sudo install -d -o awx -g awx -m 0755 /opt/ansible-runner
sudo -u awx python3 -m venv /opt/ansible-runner/venv
sudo -u awx /opt/ansible-runner/venv/bin/pip install --upgrade pip
sudo -u awx /opt/ansible-runner/venv/bin/pip install ansible-runner
sudo -u awx /opt/ansible-runner/venv/bin/ansible-runner --version
```

> **In `/opt`, not under `/var/lib/receptor`.** That directory is receptor's datadir — it is `0700`
> and receptor writes work units into it. A venv buried there is unreadable to anything but `awx`
> and mixes tooling in with runtime state, so it goes where this build puts everything else it
> compiles: `/opt`, alongside `/opt/awx` and `/opt/jewel` on their own nodes.

### receptor.conf

```bash
sudo -u awx tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-exec
    datadir: /var/lib/receptor

- log-level: info

- tls-server:
    name: mesh-server
    cert: /etc/receptor/certs/ace-exec.crt
    key: /etc/receptor/certs/ace-exec.key
    requireclientcert: true
    clientcas: /etc/receptor/certs/mesh-ca.crt

- tcp-listener:
    port: 27199
    tls: mesh-server

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- control-service:
    service: control
    filename: /run/receptor/receptor.sock
    permissions: 0660

- work-command:
    worktype: ansible-runner
    command: /opt/ansible-runner/venv/bin/ansible-runner
    params: worker
    allowruntimeparams: true
    verifysignature: true
EOF
```

- **No `local-only`** — this node has a listener, so it has something to do.
- **`work-verification` and no `work-signing`.** This node only ever receives work.
- **`worktype: ansible-runner`** is the name the controller submits to on a remote node, where it
  submits `local` to itself. Get this wrong and the job fails with an unknown work type.
- **`requireclientcert: true`** is what makes the TLS mutual. Without it any client that trusts the
  CA can connect; with it, the peer must present a certificate carrying a node ID.

### The unit, and the port

```bash
sudo tee /etc/systemd/system/receptor.service >/dev/null <<'EOF'
[Unit]
Description=Receptor mesh node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=awx
Group=awx
ExecStart=/usr/local/bin/receptor --config /etc/receptor/receptor.conf
Restart=always
RestartSec=5
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now receptor
systemctl is-active receptor
```

Only the controller may reach the mesh port:

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent \
  --add-rich-rule='rule family=ipv4 source address=192.168.1.42/32 port port=27199 protocol=tcp accept'
sudo firewall-cmd --reload
sudo firewall-cmd --list-rich-rules
```

> **Install firewalld first — Fedora Cloud Base does not ship it**, so `firewall-cmd` is
> `command not found` on a fresh node and the rule is silently never added. Unlike
> [Lab 6](06-controller.md)'s gateway, turning it on here breaks nothing: `ace-exec` mounts
> `/srv/ace` as a *client* and serves nothing but the mesh port.

---

## 4. `ace-controller`: peer to it

AWX's dispatcher has no "receptor URL" setting. It **reads `/etc/receptor/receptor.conf`
directly** — the path is hardcoded in `awx/main/tasks/receptor.py` — finds the `control-service`
entry, and connects to whatever socket `filename:` names. It also reads the file for two decisions:
a `work-signing` section means AWX signs every unit it submits, and a `tls-client` section is what
it uses to reach TLS-peered nodes. **Hand-writing this file IS configuring AWX.**

```bash
sudo -u awx tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-controller
    datadir: /var/lib/receptor
    firewallrules:
      - action: reject
        tonode: ace-controller
        toservice: control

- log-level: info

- work-signing:
    privatekey: /etc/receptor/work_private_key.pem
    tokenexpiration: 1m

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- tls-client:
    name: mesh-client
    cert: /etc/receptor/certs/ace-controller.crt
    key: /etc/receptor/certs/ace-controller.key
    rootcas: /etc/receptor/certs/mesh-ca.crt

- tcp-peer:
    address: ace-exec:27199
    tls: mesh-client

- control-service:
    service: control
    filename: /run/awx-receptor/receptor.sock
    permissions: 0660

- work-command:
    worktype: local
    command: /var/lib/awx/venv/awx/bin/ansible-runner
    params: worker
    allowruntimeparams: true
    verifysignature: true

- work-kubernetes:
    worktype: kubernetes-runtime-auth
    authmethod: runtime
    allowruntimeauth: true
    allowruntimepod: true
    allowruntimeparams: true
    verifysignature: true

- work-kubernetes:
    worktype: kubernetes-incluster-auth
    authmethod: incluster
    allowruntimeauth: true
    allowruntimepod: true
    allowruntimeparams: true
    verifysignature: true
EOF
```

- **`node.id`** must equal `CLUSTER_HOST_ID` from [Lab 6](06-controller.md).
- **`local-only` is gone.** It declared an isolated mesh; this node now has a peer.
- **`work-command: local` stays.** A control node still runs project updates itself.
- **`firewallrules`** is receptor's own, not firewalld: reject mesh traffic aimed at this node's
  control service, so only the local dispatcher issues control commands.

> **Every entry must be a `key: value` mapping.** This file has two consumers with different
> parsers and AWX is the stricter one: it calls `.items()` on every list item, so a bare `- foo`
> parses as a string and takes down the dispatcher.

Same unit as `ace-exec`, with the socket path the dispatcher expects:

```bash
sudo tee /etc/systemd/system/receptor.service >/dev/null <<'EOF'
[Unit]
Description=Receptor mesh node
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
User=awx
Group=awx
ExecStart=/usr/local/bin/receptor --config /etc/receptor/receptor.conf
Restart=always
RestartSec=5
LimitNOFILE=8192

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now receptor
sudo systemctl restart supervisord
```

The mesh should now have two nodes:

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /run/awx-receptor/receptor.sock status
```

`ace-exec` in **Known Node** and a route to it is the whole point of this lab. If it is absent,
that is a TLS or a node-ID problem, not a networking one — check `journalctl -u receptor` on both
ends before touching firewalld.

---

## 5. Tell AWX the node exists

On **`ace-controller`**. Receptor knowing about a peer and AWX knowing about an instance are two
separate facts:

```bash
sudo -u awx awx-manage provision_instance --hostname=ace-exec --node_type=execution
sudo -u awx awx-manage register_queue --queuename=default --hostnames=ace-exec

# Where the controller should dial it. This has to exist before the peer link:
# register_peers refuses an instance with no address.
sudo -u awx awx-manage add_receptor_address \
  --instance ace-exec --address ace-exec --port 27199 --protocol tcp --canonical

sudo -u awx awx-manage register_peers ace-controller --peers ace-exec
sudo -u awx awx-manage list_instances
```

> **`register_peers` fails with `Peer ace-exec does not have a receptor address` if you skip the
> middle step.** Receptor already knows how to reach the node — that is what `tcp-peer` in
> `receptor.conf` is — but AWX keeps its own topology in the database and will not link two
> instances until the target has an address row. The two facts are stored separately and neither
> derives the other, which is why this lab registers the same connection twice in two different
> places.

`ace-controller` in `controlplane`, `ace-exec` in `default`, and both heartbeating with a real
capacity:

```
[controlplane capacity=28]
        ace-controller capacity=28 node_type=control version=24.6.2.dev932+g9fdfc95d3
[default capacity=18]
        ace-exec capacity=18 node_type=execution version=ansible-runner-2.4.3
```

A `version=ansible-runner-???` and `capacity=0` on the execution node means it has been registered
but has not reported in — check the peer link before anything else.

`ace-controller` in `controlplane`, `ace-exec` in `default`, and capacity on the execution node once
it heartbeats.

---

## 6. Run something

Open **`https://192.168.1.41`** and log in as the gateway admin.

**Automation Execution → Projects → Demo Project → sync.** That runs on the *control* node — a
project update is control-plane work — and going `Pending → Running → Successful` live proves the
websocket stack as well.

Then **Automation Execution → Templates → Demo Job Template → Launch**.

In order: envoy took the request on 443, authorised it against the gateway over gRPC, attached a
JWT, routed to the controller's nginx; uwsgi handed it to the API; the dispatcher scheduled it and
submitted a **signed** work unit to receptor; receptor routed it over the TLS peer to `ace-exec`;
receptor there verified the signature, spawned `ansible-runner`, which started an EE container
under podman; and the output came back up the same mesh link to the callback receiver and out over
the websocket.

| Symptom | Where to look |
|---|---|
| Job stuck in `pending` forever | `ace-exec` not in the `default` queue, or its receptor is down |
| `unknown work type ansible-runner` | `worktype` on `ace-exec` does not match what the controller submits |
| Peer never connects, no TLS error | firewalld on `ace-exec`, or `ace-exec` unresolvable in `/etc/hosts` |
| TLS handshake fails | wrong CA on one end, or a certificate with no node-ID extension |
| Fails instantly, empty `result_traceback` | EE cannot start — linger, or `/opt/ansible-runner/venv` |
| Live output never updates | websocket path — check the `/api/controller/v2/websocket/` prefix |

## Verify

```bash
sudo -u awx awx-manage list_instances
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /run/awx-receptor/receptor.sock status
```

On **`ace-exec`**, that it really was a container and really was this node:

```bash
sudo journalctl _UID=$(id -u awx) --since -10m -o cat \
  | grep -oE 'container (init|start|died|remove) .*image=[^,]+'
```

And the check this lab exists for — on the finished job, **`controller_node` and `execution_node`
are different hosts**. The decision happened on one machine and the work on another, joined by a
signed work unit over a mutually-authenticated link you built by hand.

Next: [Automation hub](08-hub.md)
