# Lab 7 — Execution: receptor and podman

## What this is

The other half of the controller: the path a job takes from "scheduled" to "actually running a
playbook on a machine".

Two pieces:

- **receptor** — a mesh daemon. The controller hands it a *signed work unit* over a local socket;
  receptor decides which node should run it and launches the process there.
- **podman** — the container runtime. An execution environment *is* a container image, and since
  AWX 18 there is no containerless job execution, so anything that runs a job needs one.

## Where it fits

[Lab 6](06-controller.md) left you a controller that schedules work and cannot run it. This lab
builds the thing on the other end of that connection-refused error.

```
   dispatcher ──signed work unit──► receptor ──► ansible-runner ──► EE container (podman)
                (local socket)
```

Read that chain carefully, because the ordering surprises people: **receptor is the parent of
podman**, not the other way around. The dispatcher never launches a container itself. It submits a
work unit; receptor's `work-command` spawns `ansible-runner`; ansible-runner starts the container.
That indirection is the whole point — it is what lets the thing running the playbook be on a
different machine from the thing that decided to run it.

## Why this is its own lab

Because on a real deployment it is a different **machine**.

The tested distributed topology this build follows has a sixth VM — a dedicated execution node —
running exactly what this lab installs, with the controller kept control-only. Execution capacity
then scales by adding execution nodes, independently of the control plane.

We fold it into the controller to save a VM, which makes it a **hybrid** node: one that both
schedules work and runs it. Everything below is what you would install on that separate machine,
minus the network hop.

> **What the hybrid shortcut costs.** With one node in the mesh there is no peer, no listener, and
> no TLS between nodes — so this lab does not build a mesh CA or issue node certificates. Work
> signing is kept regardless, because the controller signs every unit it submits, including to
> itself. If you want the mesh lesson, add a sixth VM: give it receptor, a mesh-CA-signed
> certificate pair, a `tcp-listener`, and a `work-command` of `worktype: ansible-runner`, then add a
> matching `tcp-peer` here. Nothing else in this tutorial changes.

## What you will have at the end

A job launched from the console, running to completion in a container on this machine.

All commands on **ace-controller**.

---

## 1. podman

An execution environment **is** a container image. AWX has had no containerless job execution since
version 18, so every node that runs work needs a container runtime. That is not a compromise of the
bare-metal rule — nothing you *build* runs in a container; the runtime is the job sandbox.

```bash
sudo dnf -y install podman crun
grep -q ^awx: /etc/subuid || sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 awx
sudo loginctl enable-linger awx
loginctl show-user awx --property=Linger        # want: Linger=yes

cd /tmp    # rootless podman cannot start from a 0700 home dir, and sudo -u keeps your cwd
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman pull quay.io/ansible/awx-ee:latest
```

> **Do not skip `enable-linger`, and understand why.** `/run/user/<uid>` is created by
> `systemd-logind` when a user gets their first login session and destroyed when their last session
> exits. The `awx` user never logs in — it runs services — so on a freshly booted box that directory
> does not exist. `loginctl enable-linger awx` tells logind to treat `awx` as permanently logged in:
> the directory is created at boot and kept for the life of the machine. The flag is persistent
> state on disk (`/var/lib/systemd/linger/awx`).
>
> Rootless podman keeps all its per-user state under `XDG_RUNTIME_DIR` — container state, conmon
> pid files, and the pause process holding the user namespace open. Point it at a directory that
> does not exist and it cannot start a container.
>
> **The failure is nasty because of its timing.** It works while you are SSH'd in testing (your own
> session created the directory), then fails after a reboot — or works for days and breaks the
> moment the last session on the box closes and logind tears the directory down under a running
> service. Jobs fail at container start, looking like an image problem.

Smoke-test the sandbox, and make it exercise **crypto** rather than just the shell:

```bash
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) \
  podman run --rm quay.io/ansible/awx-ee:latest ansible-playbook --version
echo $?    # want: 0
```

> On an aarch64 host this can exit **132** — a SIGILL from OpenSSL taking an accelerated code path
> that traps under the hypervisor. The fix inside containers is an environment variable AWX passes
> through: set `AWX_TASK_ENV['OPENSSL_armcap'] = '0'` in a settings fragment. x86_64 readers never
> see this.

---

## 2. Receptor

AWX's dispatcher has no "receptor URL" setting. It **reads `/etc/receptor/receptor.conf`
directly** — the path is hardcoded in `awx/main/tasks/receptor.py` — finds the `control-service`
entry, and connects to whatever socket `filename:` names. Two more behaviours follow from the same
file: if it contains a `work-signing` section, AWX signs every work unit it submits; if it contains
a `tls-client` section, AWX uses it for TLS-peered nodes.

**Hand-writing this file IS configuring AWX.** No AWX setting changes in this section.

```bash
RECEPTOR_VERSION=1.6.5
ARCH=$(uname -m); case $ARCH in x86_64) ARCH=amd64 ;; aarch64) ARCH=arm64 ;; esac
curl -fsSL -o /tmp/receptor.tgz \
  "https://github.com/ansible/receptor/releases/download/v${RECEPTOR_VERSION}/receptor_${RECEPTOR_VERSION}_linux_${ARCH}.tar.gz"
sudo tar -xzf /tmp/receptor.tgz -C /usr/local/bin receptor
/usr/local/bin/receptor --version    # want: 1.6.5
```

Directories. The datadir must be writable and **not** on tmpfs — work units have to survive a
restart:

```bash
sudo install -d -o awx -g awx -m 0750 /etc/receptor
sudo install -d -o awx -g awx -m 0700 /var/lib/receptor

sudo tee /etc/tmpfiles.d/awx-receptor.conf >/dev/null <<'EOF'
D /run/awx-receptor 0750 awx awx -
EOF
sudo tee /etc/tmpfiles.d/receptor.conf >/dev/null <<'EOF'
D /run/receptor 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/awx-receptor.conf /etc/tmpfiles.d/receptor.conf

df --output=fstype /var/lib/receptor | tail -1    # want: xfs or ext4 — NOT tmpfs
```

> **Two runtime directories, and both are created.** `/run/receptor` is receptor's own default;
> `/run/awx-receptor` is where we point the control socket, so it is unambiguous that this daemon
> belongs to the AWX side of the box. A packaged install creates both for the same reason, and
> receptor will use its default for anything we have not explicitly redirected.
>
> Left unset, receptor's datadir falls back to `/tmp/receptor` — periodically swept, and on some
> hosts tmpfs-backed, taking in-flight work units with it at reboot.

Raised file limits, because jobs open a lot of files:

```bash
sudo tee /etc/security/limits.d/awx.conf >/dev/null <<'EOF'
# AWX limits
awx soft nofile 4096
awx hard nofile 8192
EOF
```

### Work-signing keys

Even with one node, the controller signs the work it submits and verifies it before running it.
That closes a real loop: a work unit is an instruction to execute a command, and receptor will
refuse one that is not signed by a key it trusts.

```bash
sudo -u awx openssl genrsa -out /etc/receptor/work_private_key.pem 4096
sudo -u awx openssl rsa -in /etc/receptor/work_private_key.pem \
  -pubout -out /etc/receptor/work_public_key.pem
sudo chmod 0600 /etc/receptor/work_private_key.pem
sudo chmod 0644 /etc/receptor/work_public_key.pem
```

The private key must be readable by `awx` — signing happens client-side, in `receptorctl`, running
as the service user.

### receptor.conf

The format is a YAML **list** of single-key sections, not a mapping:

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

- work-signing:
    privatekey: /etc/receptor/work_private_key.pem
    tokenexpiration: 1m

- work-verification:
    publickey: /etc/receptor/work_public_key.pem

- log-level: info

# One node, no peers: this declares an isolated mesh. The `: null` is load-bearing —
# see the war story below.
- local-only: null

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

- **`node.id`** must equal `CLUSTER_HOST_ID` from [Lab 6](06-controller.md)'s configuration step.
- **`firewallrules`** is receptor's own rule, not firewalld: reject traffic *from the mesh* aimed at
  this node's control service. Only local socket clients — the dispatcher — issue control commands.
- **Both `work-signing` and `work-verification`** are here because this node both submits and runs.
- **`work-command` with `worktype: local`** is how work executes on this node. This entry, not any
  listener, is what makes jobs run.
- **The two `work-kubernetes` entries** advertise work types this node can run *in a cluster*
  rather than here. They cost nothing to declare and are what a container group targets: the
  controller submits the same kind of signed work unit, receptor launches a pod instead of a local
  container, and nothing above the dispatcher knows the difference. We do not use them in this
  tutorial — they are here because a control or hybrid node always advertises them, and leaving
  them out would quietly narrow what this node claims to be able to do.

> **War story 1 — a receptor with no backends exits cleanly, which looks like a crash loop.** With
> no listener and no peers, receptor decides it has nothing to do: it logs
> `WARNING Nothing to do - no backends are running` and **exits 0**. systemd reports a service that
> keeps stopping and `receptorctl` throws `Connection refused`, with nothing anywhere saying "you
> have no backends." `local-only` declares an isolated node deliberately and is exactly right for a
> single-node mesh. If you hit the loop, fix the config then
> `sudo systemctl reset-failed receptor` before restarting.
>
> **War story 2 — write it the way receptor's own docs do (`- local-only`) and AWX cannot read the
> file.** Receptor accepts the bare form happily: the daemon starts, `receptorctl status` prints the
> node, this lab's verify passes. Then the first project sync dies in the *dispatcher*:
> ```
> File "/opt/awx/awx/main/tasks/receptor.py", line 142, in get_receptor_sockfile
>     for entry_name, entry_data in section.items():
> AttributeError: 'str' object has no attribute 'items'
> ```
> **Why:** AWX assumes every list item is a mapping — `get_receptor_sockfile()` and
> `get_tls_client()` both call `section.items()`. YAML parses a bare `- local-only` as the *string*
> `"local-only"`, and strings have no `.items()`. It is fatal rather than cosmetic because the
> string sits *before* `control-service`, so the loop blows up before finding the socket path —
> hence a traceback about parsing rather than about connecting.
>
> **Fix:** give the key a value so YAML produces a dict. That is what AWX itself writes:
> `RECEPTOR_CONFIG_STARTER` opens with `{'local-only': None}`. **General lesson, and it applies to
> every entry in this file:** it has two consumers with different parsers, and the stricter one is
> AWX — so keep every entry a `key: value` mapping, even where receptor's documentation shows a
> bare directive.

### The unit

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
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl --socket /run/awx-receptor/receptor.sock status
# want: Node ID ace-controller, and 'local' under Secure Work Types
```

> **Expect a version warning:** `receptorctl and receptor are different versions, they may not be
> compatible`. That is not a mistake in the steps above. `receptorctl` is a Python package pinned by
> AWX's own requirements and installed into its venv; the `receptor` daemon is a release binary you
> downloaded. The two are versioned independently and rarely match exactly. The control protocol is
> stable across minor versions, so this is noise — but check it if `receptorctl` ever starts
> returning malformed output, because then it isn't.

`XDG_RUNTIME_DIR` is baked in because **receptor is the parent of podman here** — the dispatcher
never launches a container itself; it submits a work unit, receptor's work-command spawns
`ansible-runner`, and ansible-runner starts the EE. A system service gets no `XDG_RUNTIME_DIR` for
free.

---
## 3. Run something

Open **`https://192.168.56.11`** — no port — and log in as the **gateway** admin.

The console has grown a section. **Automation Execution** is there: projects, templates,
inventories, jobs. You did not rebuild the UI, restart it, or edit a line of its config. The
navigation is assembled from the gateway's service registry at page load, and you just added a row.

### Run a job

In the left navigation: **Automation Execution → Projects → Demo Project**, then click **sync** (the
circular-arrows icon).

Watch it go `Pending → Running → Successful`, live, with no page refresh. That live update is your
websocket stack — daphne, wsrelay, and the third nginx prefix — working end to end.

Then **Automation Execution → Templates → Demo Job Template → Launch**.

Output streams in as the playbook runs. What just happened, in order: envoy took the request on 443,
authorised it against the gateway over gRPC, attached a JWT, and routed to this node's nginx; uwsgi
handed it to the API; the dispatcher scheduled it; receptor received a **signed** work unit and
spawned `ansible-runner`; ansible-runner started an EE container under podman; and the output came
back through the callback receiver and out over the websocket. Every hop hand-built.

| Symptom | Where to look |
|---|---|
| Job stuck in `pending` forever | `devonly.py` still present ([Lab 6](06-controller.md)), or the dispatcher is down |
| Fails instantly, empty `result_traceback` | EE cannot start — linger (section 1 here), or exit 132 on aarch64 |
| `Execution Node` blank, or job never dispatched | `register_queue` for `default` ([Lab 6](06-controller.md)) |
| Console shows no **Automation Execution** | the registry row from [Lab 6](06-controller.md) is missing or envoy hasn't polled yet |
| Live output never updates | websocket path — check the `/api/controller/v2/websocket/` prefix |

## Verify

```bash
sudo supervisorctl status                     # eight programs RUNNING
systemctl is-active nginx supervisord receptor automation-controller
sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl --socket /run/awx-receptor/receptor.sock status
# want: Node ID ace-controller, 'local' under Secure Work Types

sudo -u awx awx-manage list_instances
# want: capacity > 0 and node_type=hybrid, in both the controlplane and default queues
```

And the check that actually matters — the one that failed at the end of Lab 6. In the console:
**Automation Execution → Projects → Demo Project → sync**, and watch it go
`Pending → Running → Successful`.

The same thing from a terminal, if you would rather not click — through the platform door, which
also proves the gateway route while you are here:

```bash
GW=https://192.168.56.11/api/controller/v2
read -s -p "gateway admin password: " GW_PW; echo

ID=$(curl -sk -u "admin:$GW_PW" $GW/projects/ \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')
J=$(curl -sk -u "admin:$GW_PW" -X POST $GW/projects/$ID/update/ \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

for i in $(seq 30); do
  curl -sk -u "admin:$GW_PW" $GW/project_updates/$J/ \
    | python3 -c 'import json,sys; print(json.load(sys.stdin)["status"])'
  sleep 6
done
# want: running -> successful
```

Then confirm it really was a container, and really was this node doing both jobs:

```bash
sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) \
  podman events --since 10m --until 1s --format '{{.Status}} {{.Image}}'
# want: init / start / died / remove against quay.io/ansible/awx-ee:latest
```

A hybrid node shows the same hostname for both `controller_node` and `execution_node` on the
finished job — the decision and the execution happened on one machine, joined only by that signed
work unit.

Next: [Automation hub](08-hub.md)
