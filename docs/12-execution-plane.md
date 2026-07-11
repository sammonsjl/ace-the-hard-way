# Lab 12 — The execution plane

## What you will have at the end

The execution plane's first node: **ace-exec** running receptor from the release binary, TLS-peered to the control node with certs from your Lab 10 CA, verifying signed work, with podman ready to sandbox jobs. (Same plane, different members later: Kubernetes via container groups — a future chapter.)

```
ace-control                              ace-exec
  receptor ── tcp-peer ──── TLS (mutual, lab CA) ────► :27199 tcp-listener ── receptor
  work-signing (private key)                            work-verification (public key)
                                                        work-command: ansible-runner worker
                                                          └── EE container under podman
```

> **Why podman appears here and only here:** an execution environment IS a container image — since AWX 18 there is no containerless job execution. On a real AAP execution node, receptor (bare metal, yours) hands the job to ansible-runner, which runs it inside the EE under podman. You built the node; podman is just the job sandbox.

Commands run on **both** nodes in this lab — each block says which.

## Names must resolve (both nodes)

The installer's preflight requires peer names to be DNS-resolvable, and our TLS certs carry DNS names. Two `/etc/hosts` lines stand in for DNS:

```bash
# on ace-control:
echo "192.168.56.20 ace-exec" | sudo tee -a /etc/hosts

# on ace-exec:
echo "192.168.56.10 ace-control" | sudo tee -a /etc/hosts
```

## Install receptor (ace-exec)

Same pinned release as Lab 11:

```bash
RECEPTOR_VERSION=1.6.5
ARCH=$(uname -m); case $ARCH in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
curl -fsSL -o /tmp/receptor.tgz \
  "https://github.com/ansible/receptor/releases/download/v${RECEPTOR_VERSION}/receptor_${RECEPTOR_VERSION}_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/receptor.tgz -C /usr/local/bin receptor
receptor --version    # want: 1.6.5

sudo install -d -o awx -g awx -m 0750 /var/lib/receptor
sudo install -d -m 0755 /etc/receptor /etc/receptor/tls /etc/receptor/tls/ca
sudo tee /etc/tmpfiles.d/receptor.conf >/dev/null <<'EOF'
d /run/receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/receptor.conf
df --output=fstype /var/lib/receptor | tail -1    # want: NOT tmpfs (installer preflight)
```

Also create the TLS dirs on **ace-control** (its mesh cert lands there too):

```bash
sudo install -d -m 0755 /etc/receptor/tls /etc/receptor/tls/ca
```

## The mesh TLS — the undocumented dark art

Here's the part no one writes down: **receptor does not verify hostnames, it verifies node IDs.** Each node's cert must carry the node ID in a SAN of type `otherName` with receptor's private OID — `1.3.6.1.4.1.2312.19.1`. Sign a normal web-style cert and the mesh fails TLS with errors that never mention the real cause. The AAP installer's `certificate_authority` role bakes this OID into every receptor cert; we do it by hand.

Rules we follow: private keys never leave the node they're born on. Only public material (CSRs, certs, the CA cert) crosses `/vagrant` — which is fine, because `/vagrant` also lives on your laptop.

**On ace-exec — key and CSR:**

```bash
sudo tee /etc/receptor/tls/receptor.cnf >/dev/null <<'EOF'
[req]
distinguished_name = dn
req_extensions = ext
prompt = no
[dn]
CN = ace-exec
[ext]
subjectAltName = DNS:ace-exec, IP:192.168.56.20, otherName:1.3.6.1.4.1.2312.19.1;UTF8:ace-exec
EOF

sudo openssl genrsa -out /etc/receptor/tls/receptor.key 2048
sudo chown awx:awx /etc/receptor/tls/receptor.key && sudo chmod 0600 /etc/receptor/tls/receptor.key
sudo openssl req -new -key /etc/receptor/tls/receptor.key \
  -config /etc/receptor/tls/receptor.cnf -out /vagrant/ace-exec.csr
```

**On ace-control — sign it with the Lab 10 CA** (the extension must be restated at signing time; `x509 -req` drops CSR extensions by default):

```bash
sudo openssl x509 -req -in /vagrant/ace-exec.csr \
  -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key -CAcreateserial \
  -days 825 -sha256 -out /vagrant/ace-exec.crt \
  -extfile <(printf "subjectAltName=DNS:ace-exec,IP:192.168.56.20,otherName:1.3.6.1.4.1.2312.19.1;UTF8:ace-exec")
```

**On ace-control — its own mesh cert** (client side of the TLS connection; key stays here):

```bash
sudo openssl genrsa -out /etc/receptor/tls/receptor.key 2048
sudo chown awx:awx /etc/receptor/tls/receptor.key && sudo chmod 0600 /etc/receptor/tls/receptor.key
sudo openssl req -new -key /etc/receptor/tls/receptor.key \
  -subj "/CN=ace-control" -out /tmp/ace-control.csr
sudo openssl x509 -req -in /tmp/ace-control.csr \
  -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key -CAcreateserial \
  -days 825 -sha256 -out /etc/receptor/tls/receptor.crt \
  -extfile <(printf "subjectAltName=DNS:ace-control,IP:192.168.56.10,otherName:1.3.6.1.4.1.2312.19.1;UTF8:ace-control")
rm /tmp/ace-control.csr

# the CA cert doubles as the mesh CA — one platform CA, like the installer
sudo cp /etc/tower/ca/ca.crt /etc/receptor/tls/ca/mesh-CA.crt
sudo cp /etc/tower/ca/ca.crt /vagrant/mesh-CA.crt

# ship the work-signing PUBLIC key (Lab 11) alongside
sudo cp /etc/receptor/work_public_key.pem /vagrant/
```

**On ace-exec — collect the public material:**

```bash
sudo cp /vagrant/ace-exec.crt /etc/receptor/tls/receptor.crt
sudo cp /vagrant/mesh-CA.crt /etc/receptor/tls/ca/mesh-CA.crt
sudo cp /vagrant/work_public_key.pem /etc/receptor/work_public_key.pem
sudo openssl verify -CAfile /etc/receptor/tls/ca/mesh-CA.crt /etc/receptor/tls/receptor.crt
# want: OK

# tidy the shared folder — nothing secret was in it, but don't leave clutter
rm -f /vagrant/ace-exec.csr /vagrant/ace-exec.crt /vagrant/mesh-CA.crt /vagrant/work_public_key.pem
```

The cert/key/CA paths (`/etc/receptor/tls/receptor.crt|key`, `/etc/receptor/tls/ca/mesh-CA.crt`) match the ones AWX's own managed configs use — downstream fidelity again.

## ansible-runner and podman (ace-exec)

The work-command needs `ansible-runner`; ansible-runner needs podman to run the EE. Pinned to the 2.4 series — record the exact version you get:

```bash
sudo dnf -y install python3.12 python3.12-pip podman
sudo pip3.12 install 'ansible-runner==2.4.*'
ansible-runner --version    # RECORD THIS
```

Rootless podman as the `awx` user needs two things the box won't have. First, subordinate UID/GID ranges — **`useradd --system` (Lab 2) does not create them**, and without them every pull fails with a user-namespace error:

```bash
grep -q ^awx: /etc/subuid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 awx
```

Second, lingering — so `/run/user/<uid>` exists for `awx` without an interactive login:

```bash
sudo loginctl enable-linger awx
```

Pre-pull the default EE (the one Lab 7's `register_default_execution_environments` registered), so the first job doesn't pay the download:

```bash
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman pull quay.io/ansible/awx-ee:latest
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman images --digests    # RECORD the digest
```

## receptor.conf on ace-exec

```bash
sudo tee /etc/receptor/receptor.conf >/dev/null <<'EOF'
---
- node:
    id: ace-exec
    datadir: /var/lib/receptor

- log-level: info

- control-service:
    service: control
    filename: /var/run/receptor/receptor.sock
    permissions: '0660'

- tls-server:
    name: mesh-server
    cert: /etc/receptor/tls/receptor.crt
    key: /etc/receptor/tls/receptor.key
    requireclientcert: true
    clientcas: /etc/receptor/tls/ca/mesh-CA.crt

- tcp-listener:
    port: 27199
    tls: mesh-server

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- work-command:
    worktype: ansible-runner
    command: /usr/local/bin/ansible-runner
    params: worker
    allowruntimeparams: true
    verifysignature: true
EOF
```

- **`worktype: ansible-runner`** — exactly this string; it's what AWX submits for execution nodes.
- **`requireclientcert: true`** — mutual TLS: the control node must present a CA-signed cert too, not just encrypt.
- **`verifysignature: true`** + `work-verification` — only work signed by the control node's private key runs here. An attacker on the network segment can't feed this node jobs.
- The local `control-service` socket is for on-box `receptorctl` debugging — the mesh can't reach it (no remote service exposure).

## The unit (ace-exec)

One difference from Lab 11: rootless podman resolves its runtime dir from `XDG_RUNTIME_DIR`, and a system service gets no such variable — jobs would fail with a cryptic "cannot find runtime directory". Bake it in:

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

The receptor listener is `27199/tcp` — the installer opens it, and without it **the mesh times out silently** (no error, just a peer that never appears):

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=27199/tcp
sudo firewall-cmd --reload
sudo firewall-cmd --list-ports    # want: 27199/tcp
```

## Peer the control node (ace-control)

Append two sections to `/etc/receptor/receptor.conf` — the TLS client identity and the peering. The `tls-client` **name must be `tlsclient`**: AWX looks up the section by that name when it submits work over a TLS peer:

```bash
sudo tee -a /etc/receptor/receptor.conf >/dev/null <<'EOF'

- tls-client:
    name: tlsclient
    rootcas: /etc/receptor/tls/ca/mesh-CA.crt
    cert: /etc/receptor/tls/receptor.crt
    key: /etc/receptor/tls/receptor.key
    mintls13: false

- tcp-peer:
    address: ace-exec:27199
    tls: tlsclient
EOF

sudo systemctl restart receptor
```

## Verify (ace-control)

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/receptor/receptor.sock status
# want: KnownConnectionCosts lists ace-exec;
#       an Advertisement from ace-exec with WorkTypes: ansible-runner

sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl \
  --socket /var/run/receptor/receptor.sock ping ace-exec
# want: replies with round-trip times
```

And prove the sandbox works end to end on **ace-exec**:

```bash
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) \
  podman run --rm quay.io/ansible/awx-ee:latest ansible --version
# want: ansible [core ...] — the EE runs rootless as awx
```

> **If the peer never appears:** three usual suspects, in order. (1) firewalld — the connection times out silently; check `sudo firewall-cmd --list-ports` on ace-exec. (2) The otherName OID — `openssl x509 -in /etc/receptor/tls/receptor.crt -noout -text | grep -A1 'Alternative'` must show the `1.3.6.1.4.1.2312.19.1` otherName; without it receptor logs a TLS verification failure that looks like a CA problem. (3) Clock skew — preflight's chrony check exists for a reason. Whatever it was: WHAT/WHY/FIX into this lab.

Next: [Instance registration](13-instance-registration.md)
