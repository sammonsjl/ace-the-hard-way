# Lab 11 — Receptor

## What you will have at the end

Receptor running on **ace-control** from the official release binary — true kubernetes-the-hard-way style, finally a real tar file — with the control socket AWX's dispatcher talks to, the **mesh root CA** and this node's mesh cert, work-signing keys, and the `local` work type advertised.

All commands on **ace-control**.

## How AWX finds receptor (read this first)

AWX's dispatcher does not have a "receptor URL" setting. It **reads `/etc/receptor/receptor.conf` directly** (the path is hardcoded in `awx/main/tasks/receptor.py`), finds the `control-service` entry, and connects to whatever socket `filename:` points at. Two more behaviors follow from the same file:

- If the config contains a `work-signing` section, AWX **signs every work unit** it submits (`ansible-runner` and `local` work types). Signing happens client-side in `receptorctl`, running as the `awx` user — so the private key must be readable by `awx`.
- If the config contains a `tls-client` section, AWX uses it for TLS-peered nodes (Lab 12 peers through it).

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

> `/usr/local/bin` gets the SELinux `bin_t` label by default — no relabel dance like Lab 8's venv. One ownership note: a packaged receptor typically creates a separate `receptor` system user to own `/etc/receptor` (group `awx`, 0750) while the **daemon itself runs as `awx`**. We skip the extra file-owner account and use `awx` for both — same effective access, one less user to reason about.

## Directories

Two runtime dirs are in play: `/var/run/receptor`, receptor's own default, and **`/var/run/awx-receptor`**, which is where we point the control socket so it's unambiguous that this daemon belongs to the AWX side of the box. We create both, use `awx-receptor`, and give the datadir a real home — it must be writable and **not** on tmpfs, because work units have to survive a restart:

```bash
sudo install -d -o awx -g awx -m 0750 /etc/receptor /etc/receptor/tls /etc/receptor/tls/ca
sudo install -d -o awx -g awx -m 0700 /var/lib/receptor

sudo tee /etc/tmpfiles.d/receptor.conf >/dev/null <<'EOF'
D /var/run/receptor 0750 awx awx -
EOF
sudo tee /etc/tmpfiles.d/awx-receptor.conf >/dev/null <<'EOF'
D /var/run/awx-receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/receptor.conf /etc/tmpfiles.d/awx-receptor.conf

df --output=fstype /var/lib/receptor | tail -1    # want: xfs (or ext4) — NOT tmpfs
```

> Datadir note: left unset, receptor falls back to `/tmp/receptor` — a directory that gets periodically swept, and on some hosts is tmpfs-backed and vanishes entirely at reboot, taking in-flight work units with it. We configure `/var/lib/receptor` deliberately and give it a 0700 tmpfiles entry; surviving reboots beats accepting the default.

## File descriptor limits

Every node that runs work gets raised nofile limits for the service user — jobs open a lot of files:

```bash
sudo tee /etc/security/limits.d/awx.conf >/dev/null <<'EOF'
# AWX limits
awx soft nofile 4096
awx hard nofile 8192
EOF
```

## podman on the control node (yes, really)

**podman + crun belong on every node that can run work — and the control node is one of them.** Control-plane work — SCM project syncs, system jobs — executes inside the control-plane EE under podman, *on this node*. That isn't a compromise of the bare-metal rule; it's the rule: an EE is a container image, so anything that runs an EE needs a container runtime. Nothing you *build* runs in a container. Same rootless setup as the execution node will get:

```bash
sudo dnf -y install podman crun
grep -q ^awx: /etc/subuid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 awx
sudo loginctl enable-linger awx

cd /tmp    # sudo -u keeps your cwd, and rootless podman can't start from a 0700 home dir
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman pull quay.io/ansible/awx-ee:latest
```

(`quay.io/ansible/awx-ee:latest` doubles as the default job EE and the control-plane EE — Lab 7's `register_default_execution_environments` registered both.)

Smoke-test the sandbox — and make it exercise **crypto**, not just the shell (see the warning below for why):

```bash
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) \
  podman run --rm quay.io/ansible/awx-ee:latest ansible-playbook --version
echo $?    # want: 0 — if you get 132, read on
```

> **War story — exit 132 on Apple-Silicon-hosted VMs.** On an aarch64 VM under VMware Fusion, the EE dies with **exit 132 (SIGILL — illegal instruction)** the moment ansible starts, and AWX shows failed project updates/jobs with an **empty** `result_traceback`. It is NOT a wrong-arch image: `podman image inspect --format '{{.Architecture}}'` says arm64, `/bin/true` and bare python run fine. The cause: the guest kernel advertises high-end ARM crypto features, OpenSSL inside the EE autodetects them and takes an accelerated code path using an instruction that traps under the hypervisor. ansible-core imports `cryptography` at startup (`ansible.cli → ansible.parsing.vault`), OpenSSL initializes, SIGILL — before any output, hence the empty traceback. **Fix:** tell OpenSSL to skip ARM capability dispatch in every EE, globally, via AWX's task environment (correctness-safe; small crypto perf cost):
>
> ```bash
> read -s -p "AWX admin password: " AWX_PW; echo
> curl -sk -u "admin:${AWX_PW}" -X PATCH https://192.168.56.10/api/v2/settings/jobs/ \
>   -H 'Content-Type: application/json' \
>   -d '{"AWX_TASK_ENV": {"OPENSSL_armcap": "0"}}' | python3 -m json.tool | grep -A2 AWX_TASK_ENV
> ```
>
> AWX merges `AWX_TASK_ENV` into every task, and ansible-runner passes it into the podman EE as `--env` — control-plane EEs and job EEs on every node, covered in one setting. For *manual* `podman run` tests (which don't go through AWX), pass `--env OPENSSL_armcap=0` yourself. General lesson: exit 132 on an EE = SIGILL — check the image arch first, but on Apple Silicon suspect a CPU-feature trap in a correct-arch image, not a bad pull.

## The mesh root CA — receptor's own PKI

Here's a genuinely under-documented corner: receptor certs are **not** made with openssl, and the mesh does **not** share the Lab 10 web CA. The `receptor` binary ships its own PKI (`--cert-init`, `--cert-makereq`, `--cert-signreq`), and that's what creates the dedicated mesh root CA. Why the special tooling: receptor verifies **node IDs, not hostnames** — each cert carries the node ID in an `otherName` SAN under receptor's private OID (`1.3.6.1.4.1.2312.19.1`), and `--cert-makereq nodeid=...` is what injects it. Sign a normal web cert instead and the mesh fails TLS with errors that never mention the real cause.

Create the CA — the CN is free-form, since receptor authenticates on node IDs rather than names:

```bash
sudo /usr/local/bin/receptor --cert-init commonname="ACE Nodes Mesh ROOT CA" bits=4096 \
  outcert=/etc/receptor/tls/ca/mesh-CA.crt \
  outkey=/etc/receptor/tls/ca/mesh-CA.key
sudo chown awx:awx /etc/receptor/tls/ca/mesh-CA.crt /etc/receptor/tls/ca/mesh-CA.key
sudo chmod 0640 /etc/receptor/tls/ca/mesh-CA.crt /etc/receptor/tls/ca/mesh-CA.key
```

> Files are listed explicitly — no `mesh-CA.*` — because **wildcards expand in YOUR shell, before sudo runs**. `/etc/receptor/tls` is 0750 awx-owned; your login shell can't read it, the glob matches nothing, and the command fails with a baffling "No such file or directory". (Automating this with Ansible never hits it — the `file` module takes literal paths.)

Then this node's mesh cert — request and sign, both on this box (it's the CA host). Cert files are named after the node (`/etc/receptor/tls/<node>.crt`), so the mesh stays readable as it grows:

```bash
sudo /usr/local/bin/receptor --cert-makereq bits=4096 commonname=ace-control nodeid=ace-control \
  dnsname=ace-control ipaddress=192.168.56.10 \
  outreq=/etc/receptor/tls/ace-control.csr \
  outkey=/etc/receptor/tls/ace-control.key

sudo /usr/local/bin/receptor --cert-signreq verify=yes \
  cacert=/etc/receptor/tls/ca/mesh-CA.crt \
  cakey=/etc/receptor/tls/ca/mesh-CA.key \
  req=/etc/receptor/tls/ace-control.csr \
  outcert=/etc/receptor/tls/ace-control.crt \
  notafter="$(date --rfc-3339=seconds -d '+2 years' | sed 's/ /T/')"

sudo chown awx:awx /etc/receptor/tls/ace-control.crt /etc/receptor/tls/ace-control.key
sudo chmod 0640 /etc/receptor/tls/ace-control.key
sudo rm /etc/receptor/tls/ace-control.csr

# see the dark art with your own eyes — the receptor OID in the SAN:
sudo openssl x509 -in /etc/receptor/tls/ace-control.crt -noout -text | grep -A2 'Alternative'
# want: otherName (1.3.6.1.4.1.2312.19.1), DNS:ace-control, IP:192.168.56.10
```

## Work-signing keypair

Control signs, execution verifies. RSA 4096 (pkcs1), owned `root:awx` 0640: root writes it, awx (receptorctl, doing the signing) reads it, nobody else:

```bash
sudo openssl genrsa -out /etc/receptor/work_private_key.pem 4096
sudo openssl rsa -in /etc/receptor/work_private_key.pem -pubout \
  -out /etc/receptor/work_public_key.pem
sudo chown root:awx /etc/receptor/work_private_key.pem /etc/receptor/work_public_key.pem
sudo chmod 0640 /etc/receptor/work_private_key.pem /etc/receptor/work_public_key.pem
```

The **public** key travels to ace-exec in Lab 12; the private key never leaves this box.

## receptor.conf — written by hand

The format is a YAML **list** of single-key sections, not a mapping — an easy thing to get wrong. This is the full shape for a control node:

```bash
sudo -u awx tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-control
    datadir: /var/lib/receptor
    firewallrules:
      - action: reject
        tonode: ace-control
        toservice: control

- work-signing:
    privatekey: /etc/receptor/work_private_key.pem
    tokenexpiration: 1m

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- log-level: info

# no mesh peers yet — see the note below; Lab 12 REPLACES this with the tcp-peer
- local-only

- control-service:
    service: control
    filename: /var/run/awx-receptor/receptor.sock
    permissions: 0660
    tls: tls_server

- tls-server:
    name: tls_server
    cert: /etc/receptor/tls/ace-control.crt
    key: /etc/receptor/tls/ace-control.key
    clientcas: /etc/receptor/tls/ca/mesh-CA.crt
    requireclientcert: true

- tls-client:
    name: tls_client
    cert: /etc/receptor/tls/ace-control.crt
    key: /etc/receptor/tls/ace-control.key
    rootcas: /etc/receptor/tls/ca/mesh-CA.crt
    insecureskipverify: false

- work-command:
    worktype: local
    command: /var/lib/awx/venv/awx/bin/ansible-runner
    params: worker
    allowruntimeparams: true
    verifysignature: true
EOF
```

- **`node.id`** must equal `CLUSTER_HOST_ID` from Lab 6 — AWX addresses work by node ID.
- **`firewallrules`** is a receptor-level rule (not firewalld): reject any traffic *from the mesh* aimed at this node's control service. Only local socket clients (the dispatcher) issue control commands.
- **Both `work-signing` and `work-verification`** live on the control node — it signs what it sends AND verifies what it runs. `verifysignature: true` on the local work-command closes that loop.
- **`control-service`** at the socket path from the Directories section above, `0660`, with `tls: tls_server` — TLS applies when the control service is reached over the network; local unix-socket clients like `receptorctl` and the dispatcher connect plain.
- **`tls_server` / `tls_client`** are just the names we give these sections. AWX discovers the `tls-client` section by scanning the config — the name itself just has to be referenced consistently (Lab 12's `tcp-peer` uses it).
- **`work-command` (local)** is how control-plane work (project updates, system jobs) would execute *on this node* — see the warning below.
- **`local-only`** — a war story. Without it, this config has **no backends** (no listener, no peers — those come in Lab 12), and receptor treats that as "nothing to do": it logs `WARNING Nothing to do - no backends are running` and exits cleanly, which looks like a crash loop from systemd and makes `receptorctl` throw `Connection refused`. `- local-only` is exactly what a single controller with no listener needs: it means "run as an isolated node" — remove it the moment a real peer exists (Lab 12 does). If you hit the crash loop first: fix the config, then `sudo systemctl reset-failed receptor` before restarting.

> **How `local` work actually runs:** the dispatcher submits it to receptor; receptor's work-command spawns `ansible-runner worker`; ansible-runner starts the control-plane EE under the podman you just installed. Note the chain — **receptor is the parent of podman here**, which is why the unit below carries `XDG_RUNTIME_DIR` (rootless podman needs it, and system services don't get it for free).

## The unit

The unit runs receptor as `awx` and ties it to the controller family with `PartOf` — restart `automation-controller`, receptor restarts with it. `XDG_RUNTIME_DIR` is baked in because receptor spawns the control-plane EE (see the note above):

```bash
AWX_UID=$(id -u awx)
sudo tee /etc/systemd/system/receptor.service >/dev/null <<EOF
[Unit]
Description=Receptor mesh node
After=network-online.target
Wants=network-online.target
PartOf=automation-controller.service

[Service]
Type=simple
User=awx
Group=awx
Environment=XDG_RUNTIME_DIR=/run/user/${AWX_UID}
ExecStart=/usr/local/bin/receptor --config /etc/receptor/receptor.conf
ExecReload=/bin/kill -HUP \$MAINPID
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable --now receptor
```

## Verify

`receptorctl` is already in the AWX venv (it's an AWX dependency):

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/awx-receptor/receptor.sock status
# want: Node ID: ace-control, and "local" under Work types

sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/awx-receptor/receptor.sock work list
# want: {} — empty, but answering
```

If `status` prints the node and `work list` answers, AWX's dispatcher can reach receptor the same way — the mesh of one is up.

Next: [The execution plane](12-execution-plane.md)
