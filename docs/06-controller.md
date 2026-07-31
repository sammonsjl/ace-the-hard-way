# Lab 6 — The automation controller

## What this is

The controller is the automation engine: it stores your projects, inventories and credentials,
decides when a job should run, hands that job to a mesh for execution, and streams the output back
to whoever is watching.

Its API is AWX. Around that sit seven other processes — a task dispatcher, a callback receiver, a
websocket relay, a heartbeat, a log shipper — plus receptor, which is how work actually leaves the
controller and reaches a machine that will run it.

## Where it fits

This is the component people mean when they say "the automation platform". Everything else
supports it: the gateway fronts it, the database stores it, hub feeds it content, EDA triggers it.

```
   console ──► envoy :443 ──► /api/controller/ ──► ace-controller :443 nginx
                                                        │
                              ┌─────────────────────────┴────────────────┐
                              │  uwsgi (API)      dispatcher (scheduling)│
                              │  daphne (ws)      callback receiver      │
                              │  wsrelay          ws-heartbeat           │
                              │  rsyslogd + configurer                   │
                              └─────────────────────────┬────────────────┘
                                                        │ signed work unit
                                                   receptor
                                                        │
                                                 ansible-runner
                                                        │
                                              EE container (podman)
```

**This node is a hybrid.** A production deployment of this topology splits that last column onto a
separate execution VM and keeps the controller control-only, so execution capacity can scale
independently. We fold the two together to save a machine. The work still travels the same path —
the controller signs a work unit, submits it to receptor, receptor spawns `ansible-runner`, and
ansible-runner starts a container — it just never crosses a network to do it.

> **What that costs, stated plainly.** With one node in the mesh there is no peer, no listener, and
> no TLS between nodes, so this lab does not build a mesh CA or issue node certificates. If you
> want that lesson, add a sixth VM as an execution node: give it receptor, a mesh CA-signed
> certificate pair, a `tcp-listener`, and a `work-command` of `worktype: ansible-runner`, then add
> a matching `tcp-peer` here. Everything else in this lab is unchanged. Work signing is kept
> regardless — the controller signs every unit it submits, including to itself.

## What you will have at the end

The controller registered behind the gateway, appearing in the console you built in
[Lab 5](05-gateway.md), and a job launched from that console running to completion in a container
on this machine.

All commands on **ace-controller** unless stated otherwise.

```bash
vagrant ssh ace-controller
```

---

## 1. Build AWX from source

We track `devel` rather than a release tag: release tags are cut against AWX's containerised
deployment story, while `devel` is where the packaging behaviour this tutorial leans on actually
lives. The trade is reproducibility — `devel` moves daily — so **record the commit you built**.

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel
python3.12 --version        # record the exact version
```

`libffi-devel` → `cffi`; `libpq-devel`/`postgresql-devel` → `psycopg`; `openldap-devel` +
`cyrus-sasl-devel` → `python-ldap`; `openssl-devel` → several crypto builds. When a wheel build
fails, read *up* past pip's summary to the first `fatal error:` line — that names the header, and
the header names the package.

```bash
sudo install -d -o awx -g awx /opt/awx
sudo -u awx git clone --branch devel https://github.com/ansible/awx.git /opt/awx
sudo -u awx git -C /opt/awx rev-parse --short HEAD  # RECORD THIS

sudo -u awx python3.12 -m venv /var/lib/awx/venv/awx
sudo -u awx bash <<'AWXEOF'
set -euo pipefail
source /var/lib/awx/venv/awx/bin/activate
cd /opt/awx

# 1. toolchain bootstrap — PEP-517-era versions, so builds behave on 3.12
pip install --upgrade pip setuptools wheel setuptools_scm

# 2. frozen + git requirements in one resolve, C extensions compiled from source
cat requirements/requirements.txt requirements/requirements_git.txt \
  | pip install --no-binary cffi,pycparser,psycopg -r /dev/stdin

# 3. upstream removes a few legacy packages after installing
if [ -f requirements/requirements_tower_uninstall.txt ]; then
  pip uninstall -y -r requirements/requirements_tower_uninstall.txt || true
fi

# 4. editable install of AWX itself (the modern 'make develop')
pip install -e .
AWXEOF
```

### Make it a release build — delete `devonly`

This one line is the difference between a working controller and one where **every job hangs in
`pending` forever** with nothing in the logs saying why.

```bash
sudo rm -f /opt/awx/awx/devonly.py
```

AWX decides development-vs-production **not** from an environment variable but from a marker file:
`awx/__init__.py` does `import awx.devonly` and sets `MODE = 'development'` if it succeeds. That
file ships in a source checkout and is stripped from a release package — its own header says so.

> **Why it's fatal, and why it hides.** `MODE` gates the task manager:
> ```python
> if MODE == 'development' and settings.AWX_DISABLE_TASK_MANAGERS:
>     return          # skip scheduling
> manager().schedule()
> ```
> With `devonly` present `MODE` is `'development'` even though you set `AWX_MODE=production`
> everywhere — the variable picks the *settings files*, the import decides `MODE`. So the guard
> evaluates `settings.AWX_DISABLE_TASK_MANAGERS`, which **does not exist in production settings**.
> The scheduled task raises `AttributeError` every tick, the dispatcher swallows it, and jobs sit
> in `pending` while everything else looks healthy. **General lesson: an `AttributeError` on a
> settings name means a mode mismatch — check `devonly` and the process environment first.**

### The `awx-manage` wrapper

```bash
sudo tee /usr/bin/awx-manage >/dev/null <<'EOF'
#!/bin/bash
# hand-written PATH wrapper for the venv's awx-manage
export AWX_MODE=production
export HOME=${HOME:-/var/lib/awx}
exec /var/lib/awx/venv/awx/bin/awx-manage "$@"
EOF
sudo chmod 0755 /usr/bin/awx-manage
```

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/pip show awx | grep -E '^(Name|Version)'
# want: the version — this check is settings-free, which is the point

sudo -u awx awx-manage --version 2>&1 | tail -1
# want (for now): a complaint about missing configuration. That error is the wrapper WORKING:
# production mode reads /etc/tower, which section 2 hasn't written yet.
```

> Every `awx-manage` subcommand fails until section 2, not just `--version`. `manage()` calls
> `prepare_env()` first, and that reads `settings.DEBUG` — which forces the settings to load before
> any argument parsing happens. Use `pip show awx` when you want the version without configuration.

---

## 2. Configuration

```bash
sudo bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/tower/SECRET_KEY'
sudo chown root:awx /etc/tower/SECRET_KEY
sudo chmod 0640    /etc/tower/SECRET_KEY
sudo -u awx head -c 8 /etc/tower/SECRET_KEY >/dev/null && echo "awx can read SECRET_KEY — good"
```

> **`root:awx 0640`, not `0400`.** `/etc/tower` is root-owned ([Lab 2](02-vms.md)) so the service
> reads its configuration and can never rewrite it — which means the key's *group* is what grants
> access. `settings.py` below does `open('/etc/tower/SECRET_KEY','rb').read()` and every AWX process
> runs as `awx`. A root-owned `0400` file looks stricter and simply cannot be read; you get a
> `PermissionError` raised inside Django's settings import, nowhere near anything naming this file.

```bash
sudo tee /etc/tower/settings.py >/dev/null <<'EOF'
# hand-written /etc/tower/settings.py

STATIC_ROOT = '/var/lib/awx/public/static'
PROJECTS_ROOT = '/var/lib/awx/projects'
JOBOUTPUT_ROOT = '/var/lib/awx/job_status'

SECRET_KEY = open('/etc/tower/SECRET_KEY', 'rb').read().strip()

ALLOWED_HOSTS = ['*']

SERVER_EMAIL = 'root@localhost'
DEFAULT_FROM_EMAIL = 'webmaster@localhost'
EMAIL_SUBJECT_PREFIX = '[AWX] '
EOF
```

**`ALLOWED_HOSTS = ['*']` is load-bearing.** Django in production rejects every request with a bare
`400` when it is empty, and AWX's `defaults.py` leaves it empty. You will not notice until nginx is
in front and every `/api/` call answers *"The request could not be understood by the server"* while
all eight processes sit there running innocently. The wildcard is acceptable here because nginx is
the only front door and Django still validates origins for CSRF.

The database — remote now, on ace-db:

```bash
sudo tee /etc/tower/conf.d/postgres.py >/dev/null <<'EOF'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'awx',
        'USER': 'awx',
        'PASSWORD': 'CHANGE-ME-awx',
        'HOST': 'ace-db',
        'PORT': 5432,
    }
}
EOF
sudo vim /etc/tower/conf.d/postgres.py    # the real password from Lab 4
```

The websocket secret and this node's identity:

```bash
sudo bash -c 'echo "BROADCAST_WEBSOCKET_SECRET = \"$(openssl rand -base64 32)\"" > /etc/tower/conf.d/channels.py'
sudo tee /etc/tower/conf.d/cluster_host_id.py >/dev/null <<'EOF'
CLUSTER_HOST_ID = "ace-controller"
EOF
```

`CLUSTER_HOST_ID` must match the receptor `node.id` in section 5 and the hostname you register in
section 4 — AWX addresses work by node ID, and a mismatch means jobs dispatched to a node that
does not exist.

Then settle permissions in one pass. `postgres.py` holds a password and `sudo tee` creates files
world-readable:

```bash
sudo chown root:awx /etc/tower/settings.py /etc/tower/conf.d/*.py
sudo chmod 0640     /etc/tower/settings.py /etc/tower/conf.d/*.py
sudo -u awx cat /etc/tower/conf.d/channels.py >/dev/null && echo "awx can read conf.d — good"
```

```bash
sudo -u awx awx-manage check
```

Expect **one warning and no errors**: `staticfiles.W004` about `/opt/awx/awx/ui/build`. That
warning is permanent and correct — there is no controller UI to build. The console belongs to the
gateway, and you built it in Lab 5. AWX keeps that directory in `STATICFILES_DIRS` because a source
checkout is *expected* to compile a front end into it; a release ships the directory holding a
single empty `index.html`.

---

## 3. Database initialisation

```bash
sudo -u awx awx-manage migrate --noinput
sudo -u awx bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME awx-manage createsuperuser \
  --username admin --email admin@example.com --noinput'
```

Migrations take several minutes against a remote database. If they fail on connection rather than
on schema, go back to [Lab 4](04-postgresql.md)'s error table — the message tells you which link
broke.

> That superuser is a *fallback*. Once this node is registered with the gateway in section 8, the
> controller accepts only gateway-issued identities and you log in with the **gateway's** admin
> account instead. Create it anyway: it is how you get in if the trust handshake goes wrong.

---

## 4. Register this node — as a hybrid

```bash
sudo -u awx awx-manage provision_instance --hostname="$(hostname)" --node_type=hybrid
sudo -u awx awx-manage register_queue --queuename=controlplane --hostnames="$(hostname)"
sudo -u awx awx-manage register_queue --queuename=default      --hostnames="$(hostname)"
```

**Both queues, and that is the whole point of a hybrid node.** `controlplane` is where AWX puts its
own housekeeping — project updates, inventory syncs, scheduled system jobs. `default` is where user
jobs go. On a split deployment the controller is in `controlplane` only and execution nodes are in
`default`. Here one machine is in both.

```bash
sudo -u awx awx-manage create_preload_data
sudo -u awx awx-manage register_default_execution_environments
sudo -u awx awx-manage list_instances
# want: ace-controller listed, node_type=hybrid, capacity=0 (nothing is running yet)
```

`capacity=0` and `version=?` are expected here — the instance only reports capacity once its
processes are up and heartbeating, which happens in section 7.

---

## 5. podman, and why it is here

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

## 6. Receptor

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
sudo systemd-tmpfiles --create /etc/tmpfiles.d/awx-receptor.conf

df --output=fstype /var/lib/receptor | tail -1    # want: xfs or ext4 — NOT tmpfs
```

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
EOF
```

- **`node.id`** must equal `CLUSTER_HOST_ID` from section 2.
- **`firewallrules`** is receptor's own rule, not firewalld: reject traffic *from the mesh* aimed at
  this node's control service. Only local socket clients — the dispatcher — issue control commands.
- **Both `work-signing` and `work-verification`** are here because this node both submits and runs.
- **`work-command` with `worktype: local`** is how work executes on this node. This entry, not any
  listener, is what makes jobs run.

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

## 7. The processes

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/pip install uwsgi
```

uwsgi must be pip-built inside the venv: that build is **monolithic**, with the venv's Python
compiled into the binary, which is what lets it import `awx` and load the venv's C extensions. A
distro uwsgi is **modular** — its plugin links the *system* interpreter — and gives `ImportError` at
best. [Appendix A1](a1-epel-uwsgi-conflict.md) breaks this on purpose.

supervisord is the opposite case and can live system-wide, because it only ever *spawns* processes:

```bash
sudo dnf -y install python3.12-pip
sudo python3.12 -m pip install supervisor
sudo ln -sf /usr/local/bin/supervisord  /usr/bin/supervisord
sudo ln -sf /usr/local/bin/supervisorctl /usr/bin/supervisorctl
sudo supervisorctl version    # want: a version, not "command not found"
```

> **The symlinks are required.** AWX restarts its own processes by shelling out to a **bare**
> `supervisorctl`, resolved from `PATH`, reading its **default** config path — no `-c`, no
> environment variable. From `awx/main/utils/reload.py`:
> ```python
> args = ['supervisorctl']
> args.extend([command, ':'.join(['tower-processes', service])])
> ```
> `/usr/bin/supervisorctl` plus `/etc/supervisord.conf` is exactly what that expects. Rocky's `sudo`
> also excludes `/usr/local` from its `secure_path`, so without the links every `sudo supervisorctl`
> in this lab is `command not found`.
>
> **This is also why supervisord and not eight systemd units.** Native units would be nicer in every
> way except the one that matters: remove supervisord and AWX's own restart calls have nothing to
> talk to, so changing a logging setting in the API fails silently while everything looks healthy.

### nginx package, and the socket directory

```bash
sudo dnf -y module enable nginx:1.24
sudo dnf -y install nginx
sudo usermod -aG nginx awx

sudo install -d -o nginx -g nginx -m 2775 /var/run/tower
sudo tee /etc/tmpfiles.d/tower.conf >/dev/null <<'EOF'
D /run/tower 2775 nginx nginx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tower.conf
ls -ld /var/run/tower          # want: drwxrwsr-x nginx nginx — note the 's'
```

The directory is `nginx:nginx` with the **setgid** bit, not `awx:awx`. nginx is the one *reading*
these sockets, and setgid makes every socket `awx` creates there inherit the `nginx` group.

### rsyslog groundwork

Do this before writing the program list, so rsyslogd starts cleanly the first time:

```bash
sudo dnf -y install rsyslog
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/rsyslog /var/lib/awx/rsyslog/conf.d
sudo install -d -o awx -g awx -m 0750 /var/run/awx-rsyslog
sudo tee /etc/tmpfiles.d/rsyslog.conf >/dev/null <<'EOF'
D /run/awx-rsyslog 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/rsyslog.conf

sudo -u awx tee /var/lib/awx/rsyslog/rsyslog.conf >/dev/null <<'EOF'
$WorkDirectory /var/lib/awx/rsyslog
$MaxMessageSize 700000
$IncludeConfig /var/lib/awx/rsyslog/conf.d/*.conf
module(load="imuxsock" SysSock.Use="off")
input(type="imuxsock" Socket="/var/run/awx-rsyslog/rsyslog.sock" unlink="on")
template(name="awx" type="string" string="%msg%")
action(type="omfile" file="/dev/null")
EOF
```

Every line does something. `SysSock.Use="off"` means *do not* take over `/dev/log` — this is a
private log shipper for AWX, not the system logger. The private socket is why that runtime directory
had to exist. `$IncludeConfig` is where `awx-rsyslog-configurer` drops external-logging destinations
when you set them in the API; the glob matching nothing is fine. And the terminal `omfile` action
consumes events when no external logger is configured — without it rsyslog complains about messages
with nowhere to go.

### uwsgi and the program list

```bash
sudo tee /etc/tower/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
socket = /var/run/tower/uwsgi.sock
chmod-socket = 660
chdir = /opt/awx
module = awx.wsgi:application
home = /var/lib/awx/venv/awx
env = AWX_MODE=production
stats = /var/lib/awx/uwsgi.stats
processes = 8
listen = 128
master = true
no-orphans = true
vacuum = true
buffer-size = 32768
harakiri = 120
harakiri-graceful-timeout = 30
harakiri-graceful-signal = 6
worker-reload-mercy = 30
max-worker-lifetime = 3600
max-requests = 100000
reload-on-rss = 1024
py-call-osafterfork = true
cheaper = 4
cheaper-algo = busyness
cheaper-initial = 4
cheaper-step = 2
EOF
sudo chown root:awx /etc/tower/uwsgi.ini
sudo chmod 0640 /etc/tower/uwsgi.ini
```

> **`cheaper` must be strictly lower than `processes`.** It is the floor for adaptive worker
> scaling, not the target. Set them equal and uwsgi refuses to start with
> `invalid cheaper value: must be lower than processes`, then exits fast enough that supervisor
> reports `FATAL Exited too quickly` — sending you to look at supervisor instead of at uwsgi.

Now supervisord's own config and the eight programs:

```bash
sudo install -d -o root -g root -m 0755 /var/log/supervisor /etc/supervisord.d /var/run/supervisor
sudo tee /etc/tmpfiles.d/supervisor.conf >/dev/null <<'EOF'
D /run/supervisor 0755 root root -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/supervisor.conf

sudo tee /etc/supervisord.conf >/dev/null <<'EOF'
[unix_http_server]
file = /var/run/supervisor/supervisor.sock
chown = awx:awx

[supervisord]
umask = 022
minfds = 4096
logfile = /var/log/supervisor/supervisord.log
logfile_maxbytes = 50MB
logfile_backups = 10
loglevel = info
pidfile = /var/run/supervisord.pid
childlogdir = /var/log/supervisor
nodaemon = false

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl = unix:///var/run/supervisor/supervisor.sock

[include]
files = supervisord.d/*.ini
EOF

sudo tee /etc/systemd/system/supervisord.service >/dev/null <<'EOF'
[Unit]
Description=Process Monitoring and Control Daemon
After=rc-local.service

[Service]
Type=forking
ExecStart=/usr/bin/supervisord -c /etc/supervisord.conf
[Install]
WantedBy=multi-user.target
EOF
```

> **The names below are not a style choice.** `reload.py` builds
> `supervisorctl restart tower-processes:<name>` with the group name **hardcoded**, and
> `run_rsyslog_configurer` restarts the program literally called `awx-rsyslogd`. Rename either and
> those calls fail quietly, with a `FATAL`-looping configurer, while everything else looks fine.

```bash
sudo tee /etc/supervisord.d/tower.ini >/dev/null <<'EOF'
[program:awx-uwsgi]
command = /var/lib/awx/venv/awx/bin/uwsgi /etc/tower/uwsgi.ini
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopsignal = INT
stopwaitsecs = 15
stopasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-uwsgi.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-daphne]
command = /var/lib/awx/venv/awx/bin/daphne -u /var/run/tower/daphne.sock awx.asgi:channel_layer
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 5
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-daphne.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-dispatcher]
command = /var/lib/awx/venv/awx/bin/awx-manage dispatcherd
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 60
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-dispatcher.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-callback-receiver]
command = /var/lib/awx/venv/awx/bin/awx-manage run_callback_receiver
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-callback-receiver.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-wsrelay]
command = /var/lib/awx/venv/awx/bin/awx-manage run_wsrelay
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-wsrelay.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-ws-heartbeat]
command = /var/lib/awx/venv/awx/bin/awx-manage run_ws_heartbeat
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 5
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-ws-heartbeat.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-rsyslogd]
command = rsyslogd -n -i /var/run/awx-rsyslog/rsyslog.pid -f /var/lib/awx/rsyslog/rsyslog.conf
user = awx
autostart = true
autorestart = true
startsecs = 0
stopsignal = TERM
stopwaitsecs = 5
stopasgroup = true
killasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-rsyslog.log
stdout_logfile_maxbytes = 0

[program:awx-rsyslog-configurer]
command = /var/lib/awx/venv/awx/bin/awx-manage run_rsyslog_configurer
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
startsecs = 0
stopasgroup = true
killasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-rsyslog-configurer.log
stdout_logfile_maxbytes = 0
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[group:tower-processes]
programs = awx-dispatcher,awx-callback-receiver,awx-uwsgi,awx-daphne,awx-wsrelay,awx-rsyslogd,awx-rsyslog-configurer,awx-ws-heartbeat
priority = 5
EOF
```

> **`AWX_MODE=production` on every program that runs Python.** A packaged AWX never needs it,
> because a release defaults to production. A source build is pushed the other way by two separate
> things and both must be fixed: the `devonly` marker (section 1) decides `MODE`, and `AWX_MODE`
> selects the *settings files*. A process starting without it loads dev sqlite defaults instead of
> `/etc/tower` and runs half in, half out.
>
> **`startsecs = 0` on both rsyslog programs.** The configurer runs, configures, and may exit by
> design; without this supervisor calls that "exited too quickly" and parks it in `FATAL`.
>
> **`redirect_stderr` everywhere, and especially on `awx-rsyslogd`.** Skip it there and its failures
> are invisible: rsyslogd reports startup errors on stderr, supervisor discards them, and you get
> `RUNNING` over an empty log while the process restarts forever.

### The unit that does nothing

```bash
sudo tee /etc/systemd/system/automation-controller.service >/dev/null <<'EOF'
[Unit]
Description=Automation Controller service
After=network.target nginx.service supervisord.service receptor.service
Wants=nginx.service supervisord.service receptor.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF

for svc in nginx supervisord receptor; do
  sudo install -d -m 0755 "/etc/systemd/system/$svc.service.d"
  sudo tee "/etc/systemd/system/$svc.service.d/override.conf" >/dev/null <<'EOF'
[Unit]
PartOf=automation-controller.service
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable automation-controller
```

`automation-controller.service` runs `/bin/true`. It starts nothing and supervises nothing — it is a
**handle**. nginx, supervisord and receptor each declare `PartOf=automation-controller.service`, and
`PartOf` means "when that unit stops or restarts, stop or restart me too". So
`systemctl restart automation-controller` bounces the whole controller in dependency order without
that unit containing a single line about how any of it works.

`PartOf` is deliberately one-directional: stopping nginx does **not** stop the controller. You can
bounce one component without tearing down the node, but tearing down the node takes everything with
it.

> Unlike a single-box build, the database and the gateway are on *other machines* here — so this
> unit's blast radius is exactly this component, which is what it should always have been.

### SELinux, and start

```bash
sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/awx/venv/awx/bin(/.*)?'
sudo restorecon -Rv /var/lib/awx/venv/awx/bin

sudo systemctl enable --now supervisord
sudo supervisorctl status
# want: all eight tower-processes:* RUNNING
```

systemd may not execute binaries labelled `var_lib_t`, which is everything under `/var/lib`. Skip
the relabel and the children die with `203/EXEC`.

```bash
sudo -u awx awx-manage list_instances
# want: ace-controller now shows capacity > 0 and a real version — it is heartbeating
```

---

## 8. nginx

```bash
sudo tee /etc/tower/conf.d/csrf.py >/dev/null <<'EOF'
CSRF_TRUSTED_ORIGINS = [
    'https://192.168.56.11',
    'https://ace-gateway',
    'https://ace-controller',
]
EOF
sudo chown root:awx /etc/tower/conf.d/csrf.py
sudo chmod 0640 /etc/tower/conf.d/csrf.py
```

Browsers reach this service **through the gateway**, so the `Origin` they send is the gateway's, not
this node's. That is the entry that matters; the local name is there for direct debugging.

The certificate, via [Lab 3](03-internal-ca.md)'s two-step procedure:

```bash
# on ace-controller
sudo /usr/local/sbin/ace-request-cert tower /etc/tower awx cert
```
```bash
# on ace-gateway
sudo /usr/local/sbin/ace-sign-request ace-controller-tower cert
```
```bash
# back on ace-controller
sudo install -o root -g awx -m 0644 /vagrant/ace-controller-tower.cert /etc/tower/tower.cert
sudo rm -f /vagrant/ace-controller-tower.cert
sudo openssl verify /etc/tower/tower.cert       # want: OK
```

Static files for the browsable API, as **root** — `STATIC_ROOT` is a root-owned tree nginx only
reads:

```bash
sudo bash -c 'umask 022 && awx-manage collectstatic --noinput --clear'
```

> Run it as `awx` and it dies partway with a `PermissionError` *after copying some files*, which
> makes a retry look like it worked.

```bash
sudo tee /etc/nginx/nginx.conf >/dev/null <<'EOF'
worker_processes  auto;
error_log  /var/log/nginx/error.log warn;
pid        /var/run/nginx.pid;

include /usr/share/nginx/modules/*.conf;

events {
    worker_connections 1024;
}

http {
    include       /etc/nginx/mime.types;
    default_type  application/octet-stream;
    server_tokens off;

    log_format  main  '$remote_addr - $remote_user [$time_local] "$request" '
                      '$status $body_bytes_sent ($request_time) "$http_referer" '
                      '"$http_user_agent" "$http_x_forwarded_for" request-id: "$http_x_request_id"';
    access_log  /var/log/nginx/access.log  main;

    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    sendfile        on;
    tcp_nopush      on;
    tcp_nodelay     on;
    types_hash_max_size 4096;

    include /etc/nginx/conf.d/*.conf;
}
EOF
sudo rm -f /etc/nginx/conf.d/default.conf

sudo tee /etc/nginx/conf.d/automation-controller.nginx.conf >/dev/null <<'EOF'
upstream uwsgi  { server unix:/var/run/tower/uwsgi.sock; }
upstream daphne { server unix:/var/run/tower/daphne.sock; }

server {
    listen       80 default_server;
    listen  [::]:80 default_server;
    server_name  _;
    return 301 https://$host$request_uri;
}

server {
    listen       443 default_server ssl;
    listen  [::]:443 default_server ssl;
    server_name  _;

    ssl_certificate     /etc/tower/tower.cert;
    ssl_certificate_key /etc/tower/tower.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         PROFILE=SYSTEM;

    access_log /var/log/nginx/automation-controller.access.log main;
    error_log  /var/log/nginx/automation-controller.error.log;

    add_header Strict-Transport-Security max-age=15768000;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    client_max_body_size 100m;

    location /favicon.ico { alias /var/lib/awx/public/static/media/favicon.ico; }
    location /locales     { alias /var/lib/awx/public/static/awx/locales; }
    location /static      { alias /var/lib/awx/public/static; }

    location ~ ^(/websocket/|/api/websocket/|/api/controller/v2/websocket/) {
        proxy_pass http://daphne;
        proxy_http_version 1.1;
        proxy_set_header Upgrade         $http_upgrade;
        proxy_set_header Connection      $connection_upgrade;
        proxy_set_header Host            $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    location / {
        uwsgi_pass  uwsgi;
        include     /etc/nginx/uwsgi_params;
        uwsgi_read_timeout 120s;
        uwsgi_param HTTP_X_FORWARDED_FOR   $proxy_add_x_forwarded_for;
        uwsgi_param HTTP_X_FORWARDED_PROTO https;
        uwsgi_param HTTP_X_REQUEST_ID      $http_x_request_id;
    }
}
EOF
```

**443, because this component has a host to itself.** Only the gateway uses a non-standard port, and
only because envoy shares its machine.

Three details worth reading twice:

- **`location /` goes to uwsgi, not a directory.** With no SPA in front, Django owns every path —
  which is also why there is no `try_files` here and there is one in the gateway's config.
- **Three websocket prefixes.** `/websocket/` is direct, `/api/websocket/` is what the controller's
  own clients use, and `/api/controller/v2/websocket/` is what arrives once envoy is routing —
  the gateway prefixes controller traffic with `/api/controller/`. Omit the third and websockets
  work perfectly until section 9, then silently stop.
- **`uwsgi_read_timeout 120s`** matches `harakiri = 120`. If nginx gives up first, a slow request
  becomes a 504 with a worker still churning behind it.

SELinux, which a packaged AWX would have handled for you:

```bash
sudo setsebool -P httpd_can_network_connect on
sudo semanage fcontext -a -t httpd_sys_content_t '/var/lib/awx/public(/.*)?'
sudo restorecon -Rv /var/lib/awx/public

sudo dnf -y install setools-console
sudo tee /tmp/ace-nginx-upstream.te >/dev/null <<'EOF'
module ace-nginx-upstream 1.1;

require {
    type httpd_t;
    type unconfined_service_t;
    type var_run_t;
    class unix_stream_socket connectto;
    class sock_file write;
}

allow httpd_t var_run_t:sock_file write;
allow httpd_t unconfined_service_t:unix_stream_socket connectto;
EOF
checkmodule -M -m -o /tmp/ace-nginx-upstream.mod /tmp/ace-nginx-upstream.te
semodule_package -o /tmp/ace-nginx-upstream.pp -m /tmp/ace-nginx-upstream.mod
sudo semodule -i /tmp/ace-nginx-upstream.pp
```

Connecting to a unix socket crosses **two** SELinux checks, and no boolean or fcontext rule covers
the pair: `write` on the socket inode (labelled `var_run_t` by our tmpfiles entry), and `connectto`
against the *domain of the process that bound it*. Hence a two-rule policy module.

> **If you still get a 502**, check `/var/log/nginx/automation-controller.error.log`. A
> `Permission denied` on a `.sock` means classic permissions — `ls -ld /var/run/tower` should say
> `2775 nginx nginx`. Do not trust `ausearch` for this one: the sock_file denial hides behind a
> `dontaudit` rule, so the audit log stays clean while the denial keeps happening. The honest tools
> are `sudo sesearch -A -s httpd_t -t var_run_t -c sock_file` and a `setenforce 0` bisect.

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=https --add-service=http
sudo firewall-cmd --reload

sudo nginx -t
sudo systemctl enable --now nginx

curl -s https://ace-controller/api/v2/ping/ | python3 -m json.tool | head -6
# want: JSON — version, active_node "ace-controller". No -k: Lab 3's CA is trusted here.
```

That single command tests the CA chain, the SAN, and the socket path at once.

---

## 9. Join the platform

Two directions of trust, in this order. Getting it backwards is the classic failure.

### Tell the gateway about the controller

On **ace-gateway**:

```bash
read -s -p "gateway admin password: " GW_PW; echo
GW="https://127.0.0.1:8443/api/gateway/v1"

ST=$(curl -sk -u "admin:$GW_PW" "$GW/service_types/" \
     | python3 -c 'import json,sys; print({t["name"]:t["id"] for t in json.load(sys.stdin)["results"]}["controller"])')
HP=$(curl -sk -u "admin:$GW_PW" "$GW/http_ports/?name=API%20Port" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

CL=$(curl -sk -u "admin:$GW_PW" -X POST "$GW/service_clusters/" -H 'Content-Type: application/json' \
     -d "{\"name\":\"controller\",\"service_type\":$ST}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

curl -sk -u "admin:$GW_PW" -X POST "$GW/service_nodes/" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Node controller - ace-controller\",\"address\":\"192.168.56.12\",\"service_cluster\":$CL}" \
  -o /dev/null -w 'service_node: %{http_code}\n'

curl -sk -u "admin:$GW_PW" -X POST "$GW/services/" -H 'Content-Type: application/json' \
  -d "{\"name\":\"controller api\",\"api_slug\":\"controller\",\"http_port\":$HP,\"service_cluster\":$CL,
       \"is_service_https\":true,\"service_path\":\"/api/controller/\",\"service_port\":443,
       \"order\":1}" \
  -o /dev/null -w 'service: %{http_code}\n'
```

`order: 1` puts it ahead of the gateway's own catch-all at 100. `service_port: 443` and a real
address — this is a different machine now, and the row says so.

Then mint the controller's service secret:

```bash
sudo -u gateway aap-gateway-manage generate_service_secret controller
# RECORD the output
```

> If you script this, grab only the token line: `generate_service_secret` prints a `colorama`
> deprecation warning to **stdout**, above the token, and an apostrophe from that warning inside
> your `SECRET_KEY` string surfaces much later as a gateway 500.

### Tell the controller about the gateway

Back on **ace-controller**:

```bash
sudo tee /etc/tower/conf.d/gateway.py >/dev/null <<'EOF'
# JWTs: fetch the gateway's public key from this URL and trust its logins
ANSIBLE_BASE_JWT_KEY = 'https://192.168.56.11'
ANSIBLE_BASE_JWT_REDIRECT_TYPE = "awx"
ANSIBLE_BASE_JWT_VALIDATE_CERT = True
ANSIBLE_BASE_MANAGED_ROLE_REGISTRY = {'platform_auditor': {'name': 'Platform Auditor', 'shortname': 'sys_auditor'}}

# make AWX also answer at /api/controller/v2/ — the slug path the gateway routes to
OPTIONAL_API_URLPATTERN_PREFIX = "controller"

ENABLE_SERVICE_BACKED_SSO = False

# service-to-service: how AWX calls the gateway back, as itself
RESOURCE_SERVER = {
    'URL': 'https://192.168.56.11',
    'SECRET_KEY': 'PASTE-THE-GENERATED-SECRET',
    'VALIDATE_HTTPS': True,
}

REMOTE_HOST_HEADERS = ['HTTP_X_FORWARDED_FOR', 'REMOTE_ADDR', 'REMOTE_HOST']
EOF
sudo vim /etc/tower/conf.d/gateway.py    # paste the real secret
sudo chown root:awx /etc/tower/conf.d/gateway.py
sudo chmod 0640     /etc/tower/conf.d/gateway.py
sudo systemctl restart automation-controller
```

`OPTIONAL_API_URLPATTERN_PREFIX` is the quiet one that matters: without it the gateway proxies
`/api/controller/v2/...` to an AWX that only serves `/api/v2/`, and everything 404s. And
`ANSIBLE_BASE_JWT_KEY` is a **URL, not a key** — AWX fetches the gateway's public key at runtime, so
rotating at the gateway propagates automatically.

> **This closes the controller's own login, on purpose.** Once `RESOURCE_SERVER['URL']` is set,
> AWX's `settings/__init__.py` forces JWT-only authentication, with the comment *"prevents direct
> API access to Controller bypassing the platform's authentication."* From here
> `https://ace-controller/api/v2/` still renders but every call returns `401`. That is correct:
> there is one front door now, and you already built the console that uses it.

### Merge users up into the platform

Last, and only once trust exists both ways:

```bash
sudo -u awx REQUESTS_CA_BUNDLE=/etc/pki/tls/certs/ca-bundle.crt \
  awx-manage create_resource_server_users
```

> Python's `requests` validates against **certifi's** bundle, not the system trust store where Lab 3
> installed our CA — hence `REQUESTS_CA_BUNDLE`. Without it you get
> `CERTIFICATE_VERIFY_FAILED: unable to get local issuer certificate`, which reads like a broken
> certificate rather than a bundle the library cannot see.
>
> A `503` here means you are racing the restart above; wait for
> `curl -sk https://192.168.56.11/api/controller/v2/ping/` to return `200` and re-run. It is
> idempotent.

---

## 10. The payoff

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
| Job stuck in `pending` forever | `devonly.py` still present (section 1), or the dispatcher is down |
| Fails instantly, empty `result_traceback` | EE cannot start — linger (section 5), or exit 132 on aarch64 |
| `Execution Node` blank, or job never dispatched | `register_queue` for `default` (section 4) |
| Console shows no **Automation Execution** | the registry row from section 9 is missing or envoy hasn't polled yet |
| Live output never updates | websocket path — check the `/api/controller/v2/websocket/` prefix |

## Verify

```bash
sudo supervisorctl status                     # eight programs RUNNING
sudo -u awx awx-manage list_instances         # capacity > 0, node_type=hybrid
systemctl is-active nginx supervisord receptor automation-controller
curl -sk -u "admin:$GW_PW" https://192.168.56.11/api/controller/v2/ping/ | python3 -m json.tool | head -5
```

Next: [Automation hub](07-hub.md)
