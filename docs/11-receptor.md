# Lab 11 — Receptor

## What you will have at the end

Receptor running on **ace-control** from the official release binary — true kubernetes-the-hard-way style, finally a real tar file — with a control socket AWX's dispatcher can talk to, a work-signing key in place, and the `local` work type advertised.

All commands on **ace-control**.

## How AWX finds receptor (read this first)

AWX's dispatcher does not have a "receptor URL" setting. It **reads `/etc/receptor/receptor.conf` directly** (the path is hardcoded in `awx/main/tasks/receptor.py`), finds the `control-service` entry, and connects to whatever socket `filename:` points at. Two more behaviors follow from the same file:

- If the config contains a `work-signing` section, AWX **signs every work unit** it submits (`ansible-runner` and `local` work types). Signing happens client-side in `receptorctl`, running as the `awx` user — so the private key must be readable by `awx`.
- If the config contains a `tls-client` section, AWX uses it for TLS-peered nodes (that's Lab 12).

Hand-writing this file IS configuring AWX. No AWX settings change in this lab.

## Install the release binary

Pinned: **receptor v1.6.5**. The tarball contains a single static Go binary:

```bash
RECEPTOR_VERSION=1.6.5
ARCH=$(uname -m); case $ARCH in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
curl -fsSL -o /tmp/receptor.tgz \
  "https://github.com/ansible/receptor/releases/download/v${RECEPTOR_VERSION}/receptor_${RECEPTOR_VERSION}_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/receptor.tgz -C /usr/local/bin receptor
receptor --version    # want: 1.6.5
```

> `/usr/local/bin` gets the SELinux `bin_t` label by default — no relabel dance like Lab 8's venv.

## Directories

Receptor needs a datadir (work unit payloads and results live here) and a socket dir. The real installer validates the datadir is writable and **not on tmpfs** — work units must survive a receptor restart:

```bash
sudo install -d -o awx -g awx -m 0750 /var/lib/receptor
sudo install -d -m 0755 /etc/receptor

sudo tee /etc/tmpfiles.d/receptor.conf >/dev/null <<'EOF'
d /run/receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/receptor.conf

df --output=fstype /var/lib/receptor | tail -1    # want: xfs (or ext4) — NOT tmpfs
```

## Work-signing keypair

Control signs, execution verifies. Generate the pair here; the **public** key travels to ace-exec in Lab 12, the private key never leaves this box:

```bash
sudo openssl genpkey -algorithm RSA -pkeyopt rsa_keygen_bits:4096 \
  -out /etc/receptor/work_private_key.pem
sudo openssl rsa -in /etc/receptor/work_private_key.pem -pubout \
  -out /etc/receptor/work_public_key.pem
sudo chown awx:awx /etc/receptor/work_private_key.pem
sudo chmod 0600 /etc/receptor/work_private_key.pem
```

(`awx` owns the private key because signing happens in AWX's `receptorctl` client, not in the receptor daemon.)

## receptor.conf — written by hand

The format is a YAML **list** of single-key sections. Every section explained below:

```bash
sudo tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-control
    datadir: /var/lib/receptor
    firewallrules:
      - action: reject
        tonode: ace-control
        toservice: control

- log-level: info

- control-service:
    service: control
    filename: /var/run/receptor/receptor.sock
    permissions: '0660'

- work-command:
    worktype: local
    command: /var/lib/awx/venv/awx/bin/ansible-runner
    params: worker
    allowruntimeparams: true

- work-signing:
    privatekey: /etc/receptor/work_private_key.pem
    tokenexpiration: 1m
EOF
```

- **`node.id`** must equal `CLUSTER_HOST_ID` from Lab 6 (`ace-control`) — AWX addresses work by node ID.
- **`firewallrules`** is a receptor-level rule (not firewalld): reject any traffic *from the mesh* aimed at this node's control service. Only local socket clients (the dispatcher) may issue control commands. AWX's own managed config does exactly this.
- **`control-service`** is the unix socket the dispatcher discovers and connects to. `0660 awx:awx` — same wiring as the tower sockets.
- **`work-command` (local)** is how control-plane work (project updates, system jobs) would execute *on this node*. It points at the venv's `ansible-runner` — see the warning below.
- **`work-signing`** — presence of this section is what flips AWX into signing mode.

> **Honest warning about `local` work:** on a real AAP control node, `local` work runs inside a control-plane EE under podman. This control plane is bare metal **by design** — no podman. The mesh, the demo job, and everything in Labs 12–14 work fine (jobs execute on ace-exec). What can't run here: SCM project updates and the built-in cleanup system jobs. Lab 14 shows the manual-project pattern that sidesteps this, and what to do about the cleanup schedules.

## The unit

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
ExecReload=/bin/kill -HUP $MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now receptor
```

Receptor runs as `awx` — same as a real AAP controller node, and it's what lets the daemon read the datadir and the dispatcher share the socket.

## Verify

`receptorctl` is already in the AWX venv (it's an AWX dependency):

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/receptor/receptor.sock status
# want: Node ID: ace-control, and "local" under Work types

sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/receptor/receptor.sock work list
# want: {} — empty, but answering
```

If `status` prints the node and `work list` answers, AWX's dispatcher can reach receptor the same way — the mesh of one is up.

Next: [The execution plane](12-execution-plane.md)
