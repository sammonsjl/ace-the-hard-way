# Lab 13 — Receptor

## What you will have at the end

Receptor running on **ace-control** from the official release binary — true kubernetes-the-hard-way style, finally a real tar file — with the control socket AWX's dispatcher talks to, the **mesh root CA** and this node's mesh cert, work-signing keys, and the `local` work type advertised.

All commands on **ace-control**.

## How AWX finds receptor (read this first)

AWX's dispatcher does not have a "receptor URL" setting. It **reads `/etc/receptor/receptor.conf` directly** (the path is hardcoded in `awx/main/tasks/receptor.py`), finds the `control-service` entry, and connects to whatever socket `filename:` points at. Two more behaviors follow from the same file:

- If the config contains a `work-signing` section, AWX **signs every work unit** it submits (`ansible-runner` and `local` work types). Signing happens client-side in `receptorctl`, running as the `awx` user — so the private key must be readable by `awx`.
- If the config contains a `tls-client` section, AWX uses it for TLS-peered nodes (Lab 14 peers through it).

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

> `/usr/local/bin` gets the SELinux `bin_t` label by default — no relabel dance like Lab 11's venv. One ownership note: a packaged receptor typically creates a separate `receptor` system user to own `/etc/receptor` (group `awx`, 0750) while the **daemon itself runs as `awx`**. We skip the extra file-owner account and use `awx` for both — same effective access, one less user to reason about.

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
loginctl show-user awx --property=Linger        # want: Linger=yes

cd /tmp    # sudo -u keeps your cwd, and rootless podman can't start from a 0700 home dir
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman pull quay.io/ansible/awx-ee:latest
```

> **Don't skip `enable-linger` — and know how it works, because this one bites in production too.**
>
> **What linger changes.** `/run/user/<uid>` is created by `systemd-logind`, not by the kernel and not by tmpfiles. Normally it appears when a user gets their **first login session** and is **destroyed when their last session exits**. The `awx` user never logs in — it runs services — so on a freshly booted box that directory does not exist at all. `loginctl enable-linger awx` tells logind to treat `awx` as if it were always logged in: it creates `/run/user/<uid>` at boot and keeps it for the life of the machine, no session required. The flag is persistent state on disk (`/var/lib/systemd/linger/awx`), so it survives reboots — and it's equally easy to lose if the user is recreated or the box is rebuilt from an image that never had it.
>
> **Why podman cares.** Rootless podman keeps all its per-user runtime state under `XDG_RUNTIME_DIR` — container state, the conmon pid files, and the pause process that holds the user namespace open. Point it at a directory that doesn't exist and it cannot start a container. The receptor unit below hardcodes `XDG_RUNTIME_DIR=/run/user/${AWX_UID}`; linger is what guarantees the target actually exists.
>
> **WHAT breaks:** jobs and project updates fail at container start, and the failure tends to look like an EE or image problem rather than a session problem. **The tell is timing:** it works while you're still SSH'd in testing (your own `sudo` may have caused a session to exist), then fails after a reboot — or worse, works for days and breaks the moment the last session on the box closes and logind tears the directory down under a running service.
>
> **How to check, in this order:**
>
> ```bash
> loginctl show-user awx --property=Linger      # want: Linger=yes
> ls -ld /run/user/$(id -u awx)                 # want: exists, owned by awx
> ls -l /var/lib/systemd/linger/                # the persistent flag itself
> ```
>
> If `Linger=no` and the directory is missing, that's your bug: `sudo loginctl enable-linger awx`, then restart receptor so the EE gets a runtime dir that exists. Nothing about receptor's own config is wrong in this failure mode, which is exactly why it costs so much time.

(`quay.io/ansible/awx-ee:latest` doubles as the default job EE and the control-plane EE — Lab 10's `register_default_execution_environments` registered both.)

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

Here's a genuinely under-documented corner: receptor certs are **not** made with openssl, and the mesh does **not** share the Lab 12 web CA. The `receptor` binary ships its own PKI (`--cert-init`, `--cert-makereq`, `--cert-signreq`), and that's what creates the dedicated mesh root CA. Why the special tooling: receptor verifies **node IDs, not hostnames** — each cert carries the node ID in an `otherName` SAN under receptor's private OID (`1.3.6.1.4.1.2312.19.1`), and `--cert-makereq nodeid=...` is what injects it. Sign a normal web cert instead and the mesh fails TLS with errors that never mention the real cause.

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

The **public** key travels to ace-exec in Lab 14; the private key never leaves this box.

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

# no mesh peers yet — see the note below; Lab 14 REPLACES this with the tcp-peer
# the `: null` is load-bearing — see the war story below
- local-only: null

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

- **`node.id`** must equal `CLUSTER_HOST_ID` from Lab 9 — AWX addresses work by node ID.
- **`firewallrules`** is a receptor-level rule (not firewalld): reject any traffic *from the mesh* aimed at this node's control service. Only local socket clients (the dispatcher) issue control commands.
- **Both `work-signing` and `work-verification`** live on the control node — it signs what it sends AND verifies what it runs. `verifysignature: true` on the local work-command closes that loop.
- **`control-service`** at the socket path from the Directories section above, `0660`, with `tls: tls_server` — TLS applies when the control service is reached over the network; local unix-socket clients like `receptorctl` and the dispatcher connect plain.
- **`tls_server` / `tls_client`** are just the names we give these sections. AWX discovers the `tls-client` section by scanning the config — the name itself just has to be referenced consistently (Lab 14's `tcp-peer` uses it).
- **`work-command` (local)** is how control-plane work (project updates, system jobs) executes *on this node* — see the note below. This entry, not any listener, is what makes project syncs work.
- **`local-only: null`** — two war stories in one line, and they pull in opposite directions.

> **Which end of the mesh listens?** This node doesn't get a `tcp-listener`, and that is deliberate: in this topology the **execution node listens** and the control node dials out to it ([Lab 14](14-execution-plane.md) adds the `tcp-peer` here and the listener there). It could be the other way around — receptor doesn't care, and work flows in both directions regardless — but outbound-from-the-control-node is the conventional arrangement, and it means the box holding your signing key opens no ports to the mesh at all.
>
> **War story 1 — a receptor with no backends exits cleanly, which looks like a crash loop.** With no listener and no peers yet, receptor decides it has nothing to do: it logs `WARNING Nothing to do - no backends are running` and **exits 0**. systemd reports a service that keeps stopping, `receptorctl` throws `Connection refused`, and nothing anywhere says "you have no backends." `local-only` is exactly what a node in that state needs — it declares an isolated node deliberately. Lab 14 replaces it the moment a real peer exists. If you hit the crash loop first: fix the config, then `sudo systemctl reset-failed receptor` before restarting.
>
> **War story 2 — write it the way receptor's own docs do (`- local-only`) and AWX cannot read the file.** This is the trap, because receptor accepts the bare form happily: the daemon starts, `receptorctl status` prints the node, and this lab's Verify passes. Then the first project sync dies in the *dispatcher*, not in receptor:
>
> ```
> File "/opt/awx/awx/main/tasks/receptor.py", line 142, in get_receptor_sockfile
>     for entry_name, entry_data in section.items():
> AttributeError: 'str' object has no attribute 'items'
> ```
>
> **WHY:** AWX reads this file and assumes every list item is a mapping — `get_receptor_sockfile()` and `get_tls_client()` both call `section.items()` on each entry. YAML parses a bare `- local-only` as the **string** `"local-only"`, and strings have no `.items()`. It's fatal rather than cosmetic because the string sits *before* `control-service`, so the loop blows up before it ever finds the socket path — hence a traceback about parsing, not about connecting. (`work_signing_enabled()` gets away with it: it uses `'work-signing' in section`, which on a string is just a harmless substring test.)
>
> **FIX:** give the key a value so YAML produces a dict — `- local-only: null`. That's not a workaround, it's what AWX itself writes: `RECEPTOR_CONFIG_STARTER` in `awx/main/tasks/receptor.py` opens with `{'local-only': None}`. Receptor treats both forms identically. **General lesson, and it applies to every entry in this file:** it has two consumers with different parsers, and the stricter one is AWX — so keep every entry a `key: value` mapping, never a bare directive, even where receptor's own documentation shows one.

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

If `status` prints the node and `work list` answers, receptor itself is healthy — the mesh of one is up.

**Now check the other consumer.** `receptorctl` talking to the socket proves nothing about whether *AWX* can read `receptor.conf`; the two use different parsers, and only AWX's is strict (war story 2 above). Ask AWX directly, using its own functions:

```bash
sudo -u awx awx-manage shell -c "
from awx.main.tasks.receptor import read_receptor_config, get_receptor_sockfile, get_tls_client
c = read_receptor_config()
print('sockfile:', get_receptor_sockfile(c))
print('tls-client:', get_tls_client(c, True))"
# want: sockfile: /var/run/awx-receptor/receptor.sock
#       tls-client: tls_client
```

(It has to be `awx-manage shell`, not the venv's bare `python` — importing that module pulls in Django models, so the settings have to be loaded first. Plain `python -c` dies with `ImproperlyConfigured: Requested setting INSTALLED_APPS`, which tells you nothing about your receptor config.)

A blunter check that no entry is a bare directive — worth running any time you hand-edit this file, because it catches the whole class of problem in one line:

```bash
sudo python3 -c "
import yaml
d = yaml.safe_load(open('/etc/receptor/receptor.conf'))
bad = [x for x in d if not isinstance(x, dict)]
print('non-mapping entries:', bad if bad else 'none')"
# want: none   — anything listed here will crash AWX's parser
```

## Prove `local` work actually runs

Everything above tests plumbing. This tests the thing the plumbing exists for — and it's the first point in the tutorial where a real job runs, so don't move on until it passes. A project sync is control-plane work: it runs *here*, on ace-control, inside the control-plane EE.

Launch one against the demo project Lab 10 preloaded, straight from the ORM (no admin password needed):

```bash
sudo -u awx awx-manage shell -c "
from awx.main.models import Project
u = Project.objects.get(name='Demo Project').update()
print('project update id:', u.id, '| status:', u.status)"
# want: an id, and status: pending — the dispatcher takes it from here
```

Watch it land, in another shell — the container appears for a few seconds and exits:

```bash
cd /tmp    # rootless podman can't start from the 0700 vagrant home
watch -n1 "sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman ps"
```

Then confirm the outcome (substitute the id from above):

```bash
sudo -u awx awx-manage shell -c "
from awx.main.models import ProjectUpdate
u = ProjectUpdate.objects.get(id=3)
print('status        :', u.status)
print('execution node:', u.execution_node)
print('traceback     :', (u.result_traceback or '')[:400])"
# want: status: successful | execution node: ace-control | traceback empty
```

`successful` on `ace-control` means the whole chain worked: dispatcher → receptor control socket → signed `local` work unit → `ansible-runner worker` → control-plane EE under rootless podman → stdout streamed back into job events. Ours took ~7 seconds.

Three failure modes, and they're distinguishable at a glance:

| Symptom | Cause | Where it's covered |
|---|---|---|
| `AttributeError: 'str' object has no attribute 'items'` | bare directive in `receptor.conf` | war story 2 above |
| Sits in `pending` forever, nothing in podman | task manager not scheduling — `devonly`/`AWX_MODE` | [Lab 8](08-awx-source.md), Lab 11's `AWX_MODE` war story |
| Fails at container start, or exit 132 with an empty traceback | missing linger, or aarch64 SIGILL | the linger note and exit-132 war story above |

An `AttributeError: 'str' object has no attribute 'items'` here means a bare directive somewhere in the file — fix it before moving on, or the failure resurfaces as a broken project sync with a traceback that looks nothing like a config problem.

Next: [The execution plane](14-execution-plane.md)
