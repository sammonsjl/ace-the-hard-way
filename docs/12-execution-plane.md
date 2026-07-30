# Lab 12 — The execution plane

## What you will have at the end

The execution plane's first node: **ace-exec** running receptor from the release binary, TLS-peered to the control node with certs from the Lab 11 **mesh CA**, verifying signed work, with podman ready to sandbox jobs. (Same plane, different members later: Kubernetes via container groups — a future chapter.)

```
ace-control                              ace-exec
  receptor ── tcp-peer ──── TLS (mutual, mesh CA) ───► :27199 tcp-listener ── receptor
  work-signing (private key)                            work-verification (public key)
                                                        work-command: ansible-runner worker
                                                          └── EE container under podman
```

> **Why podman is here:** an execution environment IS a container image — since AWX 18 there is no containerless job execution. Receptor (bare metal, yours) hands the job to ansible-runner, which runs it inside the EE under podman. Same pattern as the controller (Lab 11): podman is the job sandbox on every node that runs work, and nowhere else.

Commands run on **both** nodes in this lab — each block says which.

## Names must resolve (both nodes)

Peer names must be resolvable — the mesh certs carry DNS names, and receptor dials peers by name. Two `/etc/hosts` lines stand in for DNS:

```bash
# on ace-control:
echo "192.168.56.20 ace-exec" | sudo tee -a /etc/hosts

# on ace-exec:
echo "192.168.56.10 ace-control" | sudo tee -a /etc/hosts
```

## Install receptor (ace-exec)

Same pinned release, same directory contract as Lab 11:

```bash
RECEPTOR_VERSION=1.6.5
ARCH=$(uname -m); case $ARCH in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
curl -fsSL -o /tmp/receptor.tgz \
  "https://github.com/ansible/receptor/releases/download/v${RECEPTOR_VERSION}/receptor_${RECEPTOR_VERSION}_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/receptor.tgz -C /usr/local/bin receptor
receptor --version    # want: 1.6.5

sudo install -d -o awx -g awx -m 0750 /etc/receptor /etc/receptor/tls /etc/receptor/tls/ca
sudo install -d -o awx -g awx -m 0700 /var/lib/receptor
sudo tee /etc/tmpfiles.d/awx-receptor.conf >/dev/null <<'EOF'
D /var/run/awx-receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/awx-receptor.conf
df --output=fstype /var/lib/receptor | tail -1    # want: NOT tmpfs — work units must survive a reboot
```

And raised nofile limits for the work user, same as the control node:

```bash
sudo tee /etc/security/limits.d/awx.conf >/dev/null <<'EOF'
# AWX limits
awx soft nofile 4096
awx hard nofile 8192
EOF
```

## The mesh cert — CSR here, signed by the CA host

Same PKI as Lab 11 (receptor's own — `nodeid=` bakes the node ID into the cert's `otherName` SAN). The flow is the one any CA should use: the key is born on the node and never leaves; the CSR travels to the CA host (ace-control), comes back as a cert. Our courier is `/vagrant` — only public material crosses it.

**On ace-exec — key and CSR:**

```bash
sudo /usr/local/bin/receptor --cert-makereq bits=4096 commonname=ace-exec nodeid=ace-exec \
  dnsname=ace-exec ipaddress=192.168.56.20 \
  outreq=/tmp/ace-exec.csr \
  outkey=/etc/receptor/tls/ace-exec.key
sudo chown awx:awx /etc/receptor/tls/ace-exec.key
sudo chmod 0640 /etc/receptor/tls/ace-exec.key
sudo cp /tmp/ace-exec.csr /vagrant/ && sudo rm /tmp/ace-exec.csr
```

**On ace-control — sign with the mesh CA, ship back cert + CA + work public key:**

```bash
sudo /usr/local/bin/receptor --cert-signreq verify=yes \
  cacert=/etc/receptor/tls/ca/mesh-CA.crt \
  cakey=/etc/receptor/tls/ca/mesh-CA.key \
  req=/vagrant/ace-exec.csr \
  outcert=/vagrant/ace-exec.crt \
  notafter="$(date --rfc-3339=seconds -d '+2 years' | sed 's/ /T/')"

sudo cp /etc/receptor/tls/ca/mesh-CA.crt /vagrant/       # cert only — the CA key stays home
sudo cat /etc/receptor/work_public_key.pem > /tmp/wpk && sudo cp /tmp/wpk /vagrant/work_public_key.pem
```

**On ace-exec — collect the public material:**

```bash
sudo install -o awx -g awx -m 0640 /vagrant/ace-exec.crt /etc/receptor/tls/ace-exec.crt
sudo install -o awx -g awx -m 0640 /vagrant/mesh-CA.crt /etc/receptor/tls/ca/mesh-CA.crt
sudo install -o awx -g awx -m 0640 /vagrant/work_public_key.pem /etc/receptor/work_public_key.pem

sudo openssl verify -CAfile /etc/receptor/tls/ca/mesh-CA.crt /etc/receptor/tls/ace-exec.crt
# want: OK
sudo openssl x509 -in /etc/receptor/tls/ace-exec.crt -noout -text | grep -A2 'Alternative'
# want: otherName (1.3.6.1.4.1.2312.19.1), DNS:ace-exec, IP:192.168.56.20

# tidy the shared folder — nothing secret was in it, but don't leave clutter
rm -f /vagrant/ace-exec.csr /vagrant/ace-exec.crt /vagrant/mesh-CA.crt /vagrant/work_public_key.pem
```

## ansible-runner and podman (ace-exec)

An execution node needs exactly this trio: `ansible-runner`, `podman`, `crun`. podman and crun come from the distro repos; ansible-runner comes from pip — pinned to the 2.4 series, record what you get:

```bash
sudo dnf -y install python3.12 python3.12-pip podman crun
sudo pip3.12 install 'ansible-runner==2.4.*'
ansible-runner --version    # RECORD THIS
```

Rootless podman as `awx` needs two things. Subordinate UID/GID ranges — **`useradd --system` (Lab 2) does not create them**, and without them every pull fails with a user-namespace error:

```bash
grep -q ^awx: /etc/subuid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 awx
```

And lingering, so `/run/user/<uid>` exists for `awx` without an interactive login:

```bash
sudo loginctl enable-linger awx
loginctl show-user awx --property=Linger        # want: Linger=yes
```

> Same trap as the control node, and it matters just as much here — this is the node where jobs actually run. If you skipped it, see [Lab 11's linger note](11-receptor.md#podman-on-the-control-node-yes-really) for what logind is doing and why a missing `/run/user/<uid>` looks like an EE failure instead of a session one.

Pre-pull the default EE (the one Lab 7's `register_default_execution_environments` registered), so the first job doesn't pay the download. **Change directory first** — `sudo -u` keeps your current working directory, and `/home/vagrant` is 0700, so rootless podman invoked from there dies with `cannot chdir to /home/vagrant: Permission denied`. Run all `sudo -u awx podman ...` commands from a world-readable directory:

```bash
cd /tmp
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman pull quay.io/ansible/awx-ee:latest
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman images --digests    # RECORD the digest
```

## receptor.conf on ace-exec

The shape of an execution node — verification but no signing, a TLS listener, no local work type:

```bash
sudo -u awx tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-exec
    datadir: /var/lib/receptor

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- log-level: info

- control-service:
    service: control
    filename: /var/run/awx-receptor/receptor.sock
    permissions: 0660
    tls: tls_server

- tls-server:
    name: tls_server
    cert: /etc/receptor/tls/ace-exec.crt
    key: /etc/receptor/tls/ace-exec.key
    clientcas: /etc/receptor/tls/ca/mesh-CA.crt
    requireclientcert: true

- tls-client:
    name: tls_client
    cert: /etc/receptor/tls/ace-exec.crt
    key: /etc/receptor/tls/ace-exec.key
    rootcas: /etc/receptor/tls/ca/mesh-CA.crt
    insecureskipverify: false

- tcp-listener:
    port: 27199
    tls: tls_server

- work-command:
    worktype: ansible-runner
    command: /usr/local/bin/ansible-runner
    params: worker
    allowruntimeparams: true
    verifysignature: true
EOF
```

- **`worktype: ansible-runner`** — exactly this string; it's what AWX submits for execution nodes. (A bare `ansible-runner` here would rely on PATH; we spell out the pip-installed path instead.)
- **`requireclientcert: true`** — mutual TLS: the control node must present a mesh-CA-signed cert too, not just encrypt.
- **`verifysignature: true`** + `work-verification` — only work signed by the control node's private key runs here. An attacker on the network segment can't feed this node jobs.
- The `tls-client` section is unused today (this node dials nobody), but every mesh node should carry one — and the v2 mesh-scaling chapter will want it.
- The local `control-service` socket is for on-box `receptorctl` debugging — the mesh can't reach it.

## The unit (ace-exec)

One difference from Lab 11's unit (besides no `PartOf` — that's controller-only): rootless podman resolves its runtime dir from `XDG_RUNTIME_DIR`, and a system service gets no such variable — jobs would fail with a cryptic "cannot find runtime directory". Bake it in:

```bash
AWX_UID=$(id -u awx)
sudo tee /etc/systemd/system/receptor.service >/dev/null <<EOF
[Unit]
Description=Receptor mesh node
After=network-online.target
Wants=network-online.target

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

## firewalld (ace-exec)

The receptor listener is `27199/tcp` and it has to be open on execution nodes. Without it **the mesh times out silently** (no error, just a peer that never appears):

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=27199/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports    # want: 27199/tcp
```

## Peer the control node (ace-control)

The mesh has a direction, and it's worth being explicit about: **controllers dial out, execution nodes listen.** That way an execution node needs no outbound reach into the control plane, and adding one is a firewall change on the new node only. Edit `/etc/receptor/receptor.conf` — the `tls_client` section from Lab 11 does the identity, `redial` keeps the link self-healing:

```bash
sudo vim /etc/receptor/receptor.conf
```

**Replace** the Lab 11 `- local-only` line (a node with a real peer must not be isolation-mode) with:

```yaml
- tcp-peer:
    address: ace-exec:27199
    redial: true
    tls: tls_client
```

```bash
sudo systemctl restart receptor
```

## Verify (ace-control)

`receptorctl ping`, as the service user — this is the check that proves the mesh, not just the process:

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/awx-receptor/receptor.sock status
# want: KnownConnectionCosts lists ace-exec;
#       an Advertisement from ace-exec with WorkTypes: ansible-runner

sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/awx-receptor/receptor.sock ping ace-exec --count 1
# want: Reply from ace-exec ...
```

And prove the sandbox works end to end on **ace-exec** (again from a readable cwd):

```bash
cd /tmp
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) \
  podman run --rm --env OPENSSL_armcap=0 quay.io/ansible/awx-ee:latest ansible-playbook --version
# want: ansible-playbook [core ...] — the EE runs rootless as awx
# exit 132 without the --env? That's Lab 11's Apple Silicon SIGILL story. AWX-launched
# jobs on this node are already covered by the global AWX_TASK_ENV setting from Lab 11.
```

> **If the peer never appears:** three usual suspects, in order. (1) firewalld — the connection times out silently; check `sudo firewall-cmd --list-ports` on ace-exec. (2) The node-ID SAN — both certs must show the `1.3.6.1.4.1.2312.19.1` otherName (the openssl check above); a cert made outside receptor's PKI fails TLS with what looks like a CA problem. (3) Clock skew — preflight's chrony check exists for a reason. Whatever it was: WHAT/WHY/FIX into this lab.

Next: [Instance registration](13-instance-registration.md)
