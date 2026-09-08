# Lab 5 — The platform gateway

## What this is

The gateway is the platform's front door and its registry. It owns the single URL you log into, the
single list of users and teams, and a database table describing every other service — from which a
proxy in front of it derives its entire routing configuration at runtime.

Two processes, doing two jobs:

- **A REST API** (`uwsgi`) — users, teams, organisations, authenticators, and the service registry.
- **A gRPC control plane** (`:50051`) — the proxy calls it to authorise every request that passes
  through.

And in front of them, **envoy**: a proxy that starts with *no routes at all* and asks the gateway
what to serve, every five seconds, over xDS.

## Where it fits

Everything else in this build registers itself here and is reached through here.

```
  browser ──► :443 envoy ──┬── xDS REST poll, 5s ──► nginx :8443 ──► gateway uwsgi :8050
                           ├── gRPC authorisation  ──►               control plane :50051
                           │
                           ├── /api/controller/ ──► ace-controller :443
                           ├── /api/galaxy/     ──► ace-hub        :443
                           └── /api/eda/        ──► ace-eda        :443
```

Note what that means for the labs that follow. The controller, hub and EDA are not "plugged into" a
proxy by editing a config file — each one **inserts rows into the gateway's database**, and envoy
picks them up on its next poll. Adding a service to this platform is an API call.

This lab builds the gateway, brings up envoy with an empty registry, and then registers the gateway
*as its own first service* — which is what opens port 443.

**Redis lives here too.** In this topology the cache is colocated with the gateway rather than
getting its own VM. The gateway uses it for sessions and its own caching; EDA connects to it across
the network for job control.

## What you will have at the end

`https://192.168.1.41` serving a real console you can log into — with nothing in it, because no
service has registered yet.

All commands on **ace-gateway** unless stated otherwise.

```bash
ssh ace-gateway
```

---

## 1. Redis

```bash
sudo dnf -y install valkey
redis-server --version
```

> **Fedora ships Valkey, not Redis.** After Redis changed its licence in 2024 Fedora replaced it
> with [Valkey](https://valkey.io/), the Linux Foundation fork, and there is no `redis` package left
> — `dnf install redis` resolves to `valkey` through a `Provides`. Install it by its real name so
> what you typed matches what you get.
>
> The compatibility surface is good and the wire protocol is identical, so the platform's Python
> clients neither know nor care. What is *not* aliased is the packaging: the service account and
> group are **`valkey`**, and the config lives in **`/etc/valkey/valkey.conf`**. The binaries
> (`redis-server`, `redis-cli`) are symlinks and `redis.service` is an alias, which is exactly what
> makes this trap quiet — every command you type appears to work right up until one wants the user
> or the config file.
>
> The socket path below stays `/run/redis/redis.sock` on purpose: that is where the RPM installer
> this build replicates puts it, and the gateway's settings name it explicitly either way.

The socket lives in its own directory, owned by `valkey`, mode `0750`:

```bash
sudo install -d -o valkey -g valkey -m 0750 /var/run/redis
sudo tee /etc/tmpfiles.d/redis.conf >/dev/null <<'EOF'
D /run/redis 0750 valkey valkey -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/redis.conf
sudo restorecon -Rv /var/run/redis
ls -ld /var/run/redis
```

> `/var/run` is a tmpfs — it is empty after every reboot, so a directory you create by hand is gone
> the moment the VM restarts and redis then fails with a bind error that says nothing about the
> real problem. `D` rather than `d` also empties it on boot, which clears a stale socket left by an
> unclean shutdown.
>
> Write `/run/...` in the tmpfiles entry, not `/var/run/...` — they are the same directory, but
> systemd calls the older spelling legacy and prints a rewrite warning on every run.
>
> SELinux labels a directory by its path, so one created by hand needs the `restorecon`.

Now the config:

```bash
sudo vim /etc/valkey/valkey.conf
```

```
port 0                                # no TCP for local clients — socket only
bind 127.0.0.1 192.168.1.41
unixsocket /run/redis/redis.sock
unixsocketperm 777
dir /var/lib/valkey
logfile /var/log/valkey/valkey.log
```

Two of those look wrong together and aren't:

- **`port 0` disables the TCP listener.** Not "bind to localhost" — off. The gateway talks to redis
  over the unix socket, which is faster and has nothing to firewall.
- **`unixsocketperm 777` looks alarming and isn't**, because the *directory* is `0750`. A process
  must be in the `valkey` group to traverse `/var/run/redis` before it can even see the socket. The
  directory is the access control; the socket mode is not a second, redundant gate.

```bash
sudo systemctl enable --now valkey
systemctl is-active valkey
```

> **The controller needs TCP next, and EDA needs it after that.** [Lab 6](06-controller.md) is
> the first thing to connect to this redis from another machine — its `BROKER_URL`,
> `CHANNEL_LAYERS` and `CACHES` all point at `ace-gateway:6379` over the network, because a
> packaged install's redis-on-the-same-box default doesn't apply to a five-node estate. [Lab 9](09-eda.md)
> reaches it the same way afterwards. It is left off here deliberately: start closed, open only
> what a component actually proves it needs — which happens in Lab 6, not here.

---

## 2. The gateway user and its layout

```bash
sudo useradd --system --home-dir /var/lib/ansible-automation-platform/gateway \
             --create-home --shell /bin/bash gateway
sudo usermod -aG valkey gateway
sudo install -d -o gateway -g gateway -m 0750 /etc/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 2775 /var/log/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 0755 /var/lib/ansible-automation-platform/venv
sudo install -d -o gateway -g gateway -m 0750 /var/cache/ansible-automation-platform/gateway
sudo chmod 0755 /var/lib/ansible-automation-platform

id gateway
```

The `valkey` group is not optional — the settings below cache on a socket in a directory only that
group can enter. Miss it and the gateway starts, then fails the moment it touches the cache.

The `venv` directory is created explicitly because the gateway's **home** is
`/var/lib/ansible-automation-platform/gateway`, one level down, so `useradd` left the parent
root-owned. Without it, creating the venv fails with a bare
`Permission denied: '/var/lib/ansible-automation-platform/venv'` that never mentions ownership.

---

## 3. Build toolchain

The gateway does SAML federation, which pulls in `python3-saml` → `xmlsec`, and LDAP, which pulls
in `python-ldap`. Both compile against native libraries:

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel \
  libxml2-devel xmlsec1-devel xmlsec1-openssl-devel libtool-ltdl-devel
```

> **One repository, no extras.** Everything above comes from Fedora's own repository, which is
> worth noticing because on RHEL and its rebuilds it does not: `xmlsec1-devel`,
> `xmlsec1-openssl-devel` and `libtool-ltdl-devel` live in CodeReady Builder there, a repo that is
> off by default, and those three are the only ones that fail without it (`No match for argument:
> xmlsec1-devel`). Fedora needs no equivalent step.
>
> **Do not install the distribution's `uwsgi` on any of these machines.** Fedora ships one, and it
> is one careless `dnf install` away from the venv-built uwsgi this platform actually runs on — a
> packaged uwsgi links the system interpreter and cannot import a venv's C extensions. Nothing in
> this tutorial needs it.

---

## 4. supervisord

The gateway's two processes run under supervisord, and so — on their own machines — do the
controller's and hub's. Same pattern each time, so it is worth doing properly once.

supervisord only ever *spawns* processes; it never imports anything from the application, so unlike
uwsgi it does not need to share an interpreter with what it runs. That is what lets it live
system-wide:

```bash
sudo python3.12 -m ensurepip --altinstall
sudo python3.12 -m pip install supervisor
sudo ln -sf /usr/local/bin/supervisord  /usr/bin/supervisord
sudo ln -sf /usr/local/bin/supervisorctl /usr/bin/supervisorctl
sudo which supervisord supervisorctl
sudo supervisord --version
```

> **`ensurepip`, because there is no `python3.12-pip` package.** Fedora packages pip only for the
> *default* interpreter — 3.14 here. The alternate versioned interpreter this build uses on all
> four components, 3.12, ships `ensurepip` with a pip wheel bundled inside instead, which is what
> bootstraps it. `--altinstall` is what stops it stamping on the
> system `pip3`. Ask dnf for `python3.12-pip` and you get `No match for argument`.
>
> Inside a venv this never comes up — `python3.12 -m venv` bootstraps pip on its own. It only
> matters here, where supervisor is installed system-wide on purpose.

> **What the symlinks are actually for.** They reproduce the end state a packaged supervisord
> would leave — binaries on `/usr/bin` — which is what [Lab 6](06-controller.md) needs: AWX
> restarts its own processes by shelling out to a **bare** `supervisorctl`, resolved from `PATH`,
> reading its **default** config path, with no `-c` and no environment variable.
>
> On Fedora they are belt-and-braces rather than load-bearing, and the `which` above shows why:
> pip installs supervisor's scripts into **both** `/usr/local/bin` and `/usr/local/sbin`, and
> Fedora's `secure_path` (`sudo grep secure_path /etc/sudoers`) begins
> `/usr/local/sbin:/usr/local/bin`, so a bare `supervisorctl` resolves to the `sbin` copy before it
> ever reaches `/usr/bin`. The copies are identical and both default to `/etc/supervisord.conf`, so
> it does not matter which one runs.
>
> It matters a great deal on RHEL and its rebuilds, where `secure_path` is
> `/sbin:/bin:/usr/sbin:/usr/bin` with no `/usr/local` at all — there, without these links, every
> `sudo supervisorctl` is `command not found` while the binary sits one directory over. Keep them:
> they cost nothing here and they are the difference between working and not if you carry this
> build to a RHEL box.

```bash
sudo install -d -o root -g root -m 0755 /var/log/supervisor /etc/supervisord.d /var/run/supervisor
sudo tee /etc/tmpfiles.d/supervisor.conf >/dev/null <<'EOF'
D /run/supervisor 0755 root root -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/supervisor.conf

sudo tee /etc/supervisord.conf >/dev/null <<'EOF'
[unix_http_server]
file = /var/run/supervisor/supervisor.sock
chown = gateway:gateway

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
sudo systemctl daemon-reload
```

`chown = gateway:gateway` on the control socket lets the service manage its own processes without
being root. On ace-controller the same line names `awx` instead, for the same reason.

---

## 5. Build the gateway

> **Here be dragons.** Jewel lives at [ansible/jewel](https://github.com/ansible/jewel): no
> releases, moving daily. The end state below is right, but requirements layout and module paths
> may drift. When the repo disagrees with a build step, the repo wins — note the difference.

> **The two requirements files install separately, and must.** `requirements.txt` is fully
> hash-pinned — 900-odd `--hash=sha256:` lines — while `requirements_git.txt` is a single
> `git+https://` URL for `django-ansible-base`. Hash-checking in pip is a *mode*, not a per-line
> property: feed it one file containing both and it refuses the whole install with
> `Can't verify hashes for these requirements because we don't have a way to hash version control
> repositories`. Two `pip install -r` calls keep the hashed set hash-checked and let the VCS
> requirement through on its own.

> **Two of the pinned C extensions are older than this compiler, and will not build.** This is the
> sharpest edge of building on Fedora, and it is worth understanding rather than working around
> blindly — see the note after the commands.

```bash
sudo install -d -o gateway -g gateway /opt/jewel
sudo -u gateway git clone https://github.com/ansible/jewel.git /opt/jewel
sudo -u gateway git -C /opt/jewel rev-parse --short HEAD

sudo -u gateway python3.12 -m venv /var/lib/ansible-automation-platform/venv/gateway
sudo -u gateway bash <<'EOF'
set -euo pipefail
source /var/lib/ansible-automation-platform/venv/gateway/bin/activate
cd /opt/jewel

pip install --upgrade pip setuptools wheel setuptools_scm

# 1. Everything except the two that will not compile, still hash-checked. The
#    awk drops each of those packages *and* its --hash continuation lines;
#    leave a stray hash behind and pip rejects the whole file. This runs FIRST
#    because it is what pins lxml — see step 3.
awk '/^(uwsgi|xmlsec)==/ {skip=1} skip {if ($0 !~ /\\$/) skip=0; next} {print}' \
  requirements/requirements.txt > /tmp/req-no-c-ext.txt
pip install -r /tmp/req-no-c-ext.txt

# 2. uwsgi links nothing from the venv, so a current one just works.
pip install uwsgi

# 3. xmlsec must link the SAME lxml the application imports, so build isolation
#    is off and it compiles against what step 1 installed. That means supplying
#    its build dependencies by hand.
pip install pkgconfig setuptools_scm
pip install --no-build-isolation --no-binary xmlsec xmlsec

# 4. --no-deps, because django-ansible-base re-pins xmlsec==1.3.13 itself.
pip install --no-deps -r requirements/requirements_git.txt
pip install --no-deps -e .
EOF
```

> **Why those three steps, and not just `pip install -r`.**
>
> `requirements.txt` pins `uwsgi==2.0.28` and `xmlsec==1.3.13`. Both are C extensions, both are
> compiled here rather than downloaded as wheels, and **neither compiles against GCC 15**:
>
> ```
> core/master_utils.c:711:34: error: passing argument 2 of 'signal' from incompatible pointer type
> ```
>
> GCC 14 promoted several long-standing C warnings — `-Wincompatible-pointer-types` among them — to
> **errors** by default. Code that built with warnings for a decade now fails outright. uwsgi fixed
> it in 2.0.31 and xmlsec in 1.3.17; the pins predate both. Nothing is wrong with the pins, and
> nothing is wrong with Fedora — the pins were simply chosen against an older toolchain, which is
> exactly what you signed up for by building on the upstream distribution. Expect to meet this
> again, and expect the enterprise rebuilds to meet it when they catch up.
>
> **Step 1 keeps hash-checking.** The other 82 packages stay hash-pinned; only the two that cannot
> build are removed. Dropping the whole file's hashes to route around two packages would be a much
> larger concession than it looks.
>
> **Step 3 is the subtle one, and getting it wrong costs you an afternoon.** `xmlsec` is a C
> extension that links `libxml2` *through* lxml, so the lxml it compiles against and the lxml the
> application imports at runtime must be the same one. pip's default build isolation defeats that:
> it builds in a throwaway environment holding the **newest** lxml, while `requirements.txt` pins
> the venv to an older one. The build succeeds, the install succeeds, `import xmlsec` on its own
> succeeds — and then the gateway starts and logs:
>
> ```
> ERROR ansible_base.authentication.authenticator_plugins.utils Failed to load urls from
> ansible_base.authentication.authenticator_plugins.saml
> (-1, 'lxml & xmlsec libxml2 library version mismatch')
> ```
>
> DAB catches that while loading its authenticator plugins, so the *visible* symptom is not a stack
> trace about xmlsec. It is that **every login fails with "Invalid username/password"** — including
> one whose password you just reset. Nothing in that message names lxml, xmlsec, or SAML.
>
> `--no-build-isolation` forces the build to use the venv's own lxml. With isolation off pip no
> longer supplies build dependencies, which is why `pkgconfig` and `setuptools_scm` go in first;
> without them the build stops at `ModuleNotFoundError: No module named 'pkgconfig'`.
>
> This is the same shape as the packaged-uwsgi trap: a C extension linked against one library and
> run against another. Worth recognising, because the error never surfaces where the mistake was.
>
> **Step 4 is `--no-deps` for a different reason.** `django-ansible-base` carries its own
> `xmlsec==1.3.13` pin, so pip re-resolves it and downloads 1.3.13 again — undoing step 3 — even
> though a working xmlsec is already installed. `--no-deps` is safe *here* precisely because
> `requirements.txt` is the complete, pinned dependency set. Do not reach for it casually elsewhere.

Confirm the build before moving on. The second line is what catches a mismatched xmlsec — check it
here rather than meeting it as a login failure six sections later:

```bash
sudo -u gateway /var/lib/ansible-automation-platform/venv/gateway/bin/python \
  -c 'import aap_gateway_api, ansible_base; print("ok")'
sudo -u gateway /var/lib/ansible-automation-platform/venv/gateway/bin/python \
  -c 'import lxml.etree, xmlsec; print("lxml + xmlsec agree")'
```

The manage entrypoint is **`aap-gateway-manage`**. Give it a PATH wrapper:

```bash
ls /var/lib/ansible-automation-platform/venv/gateway/bin/ | grep -i manage
sudo tee /usr/bin/aap-gateway-manage >/dev/null <<'EOF'
#!/bin/bash
# hand-written PATH wrapper for the venv's aap-gateway-manage.
# OPENSSL_armcap=0: the gateway imports cryptography at startup; on an aarch64 VM under a
# hypervisor OpenSSL takes an accelerated code path that SIGILLs (exit 132). No-op on x86_64.
export OPENSSL_armcap=0
exec /var/lib/ansible-automation-platform/venv/gateway/bin/aap-gateway-manage "$@"
EOF
sudo chmod 0755 /usr/bin/aap-gateway-manage
```

> **Apple Silicon.** On aarch64 the very first `aap-gateway-manage` you run exits **132** with no
> traceback. The gateway imports `cryptography` before printing anything; OpenSSL autodetects CPU
> features that trap under the hypervisor. The variable has to be in the wrapper, in `uwsgi.ini`,
> and in each supervisord program's `environment=` — all done below.

---

## 6. The certificate

The CA is on this machine ([Lab 3](03-internal-ca.md)), so both halves of the signing procedure run
here:

```bash
sudo /usr/local/sbin/ace-request-cert gateway /etc/ansible-automation-platform/gateway gateway cert
sudo /usr/local/sbin/ace-sign-request ace-gateway-gateway cert
sudo install -o root -g gateway -m 0644 \
  /srv/ace/ace-gateway-gateway.cert /etc/ansible-automation-platform/gateway/gateway.cert
sudo rm -f /srv/ace/ace-gateway-gateway.cert

sudo openssl verify /etc/ansible-automation-platform/gateway/gateway.cert
sudo openssl x509 -in /etc/ansible-automation-platform/gateway/gateway.cert -noout -ext subjectAltName
```

Note the **`.cert`** extension — jewel's configuration expects that name, which is why the scripts
take it as an argument.

---

## 7. Settings

Jewel loads `/etc/ansible-automation-platform/gateway/settings.py` automatically: its own
`settings.py` calls `load_python_file_with_injected_context('{etc}/settings.py')`, and `{etc}` is
that directory. No settings-module environment variable is involved.

```bash
sudo -u gateway bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/ansible-automation-platform/gateway/SECRET_KEY'
sudo chmod 0400 /etc/ansible-automation-platform/gateway/SECRET_KEY

sudo -u gateway tee /etc/ansible-automation-platform/gateway/settings.py >/dev/null <<'EOF'
# Gateway override settings — remote postgres on ace-db, unix-socket redis here.

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'gateway',
        'USER': 'gateway',
        'PASSWORD': 'CHANGE-ME-gateway',
        'HOST': 'ace-db',
        'PORT': 5432,
    }
}

# Jewel's 'primary' cache uses a client that assumes TLS and a dedicated redis host — wrong
# for our local socket. Replace it with a plain django_redis client.
CACHES['primary'] = {
    'BACKEND': 'django_redis.cache.RedisCache',
    'LOCATION': 'unix:///var/run/redis/redis.sock?db=4',
    'KEY_PREFIX': 'gateway',
    'OPTIONS': {'CLIENT_CLASS': 'django_redis.client.DefaultClient'},
}
CACHES['fallback']['LOCATION'] = '/var/cache/ansible-automation-platform/gateway'

ENVOY_HOSTNAME = 'ace-gateway'
GATEWAY_SECRET_KEY_FILE = '/etc/ansible-automation-platform/gateway/SECRET_KEY'
GATEWAY_CERT_FILE = '/etc/ansible-automation-platform/gateway/gateway.cert'
GATEWAY_KEY_FILE = '/etc/ansible-automation-platform/gateway/gateway.key'
GATEWAY_PATH_REWRITE_SCRIPT_FILE = '/etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua'
STATIC_ROOT = '/var/lib/ansible-automation-platform/platform/ui/static'

GRPC_SERVER_PORT = '50051'
GRPC_SERVER_PROCESSES = 2
GRPC_SERVER_MAX_THREADS_PER_PROCESS = 10

CSRF_TRUSTED_ORIGINS = ['https://192.168.1.41', 'https://ace-gateway']
FRONT_END_URL = 'https://192.168.1.41'

# Console logging off — otherwise every request is duplicated into uwsgi's log.
LOGGING['handlers']['console'] = {'class': 'logging.NullHandler'}
LOGGING['handlers']['file'] = {
    'level': 'INFO',
    'class': 'logging.handlers.RotatingFileHandler',
    'filename': '/var/log/ansible-automation-platform/gateway/gateway.log',
    'maxBytes': 1024 * 1024 * 10,
    'backupCount': 10,
    'formatter': 'simple',
    'filters': ['request_id_filter'],
}
EOF
sudo vim /etc/ansible-automation-platform/gateway/settings.py
```

The URLs carry **no port**, because envoy will own 443 on this host.

`ENVOY_HOSTNAME` is **`ace-gateway`, not `127.0.0.1`**, and that matters more than it looks. The
gateway calls *itself* through envoy during service registration, over TLS, and validates the
certificate it gets back. That certificate's SAN covers `DNS:ace-gateway` and
`IP:192.168.1.41` — a loopback address is in neither, so `127.0.0.1` produces a hostname
mismatch on a connection the gateway makes to its own machine.

---

## 8. Migrate, and create the login

```bash
sudo -u gateway aap-gateway-manage migrate
sudo -u gateway bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-gateway-manage createsuperuser \
  --username=admin --email=admin@example.com --noinput'
```

Pick a real password and record it — this is the account you log into the platform with for the
rest of the tutorial. Wrong one? `sudo -u gateway aap-gateway-manage changepassword admin`.

Then seed the **local authenticator**:

```bash
sudo -u gateway aap-gateway-manage authenticators --initialize
```

> A superuser row is not enough on its own. The gateway authenticates through pluggable
> authenticator objects, and until one exists there is no login backend — every credential,
> including the superuser you just made, is rejected with
> `{"detail":"Invalid username/password."}`. The console renders, the password is right, the user
> exists and is a superuser, and the form simply refuses. The tell is
> `aap-gateway-manage shell -c "from ansible_base.authentication.models import Authenticator;
> print(Authenticator.objects.all())"` returning an empty list.
>
> The `authenticators` subcommand comes from `django-ansible-base`, not from jewel's own command
> set, so it will not appear in jewel's `management/commands/` directory.

---

## 9. nginx

nginx terminates TLS for the gateway API and serves the console's static files. It listens on
**8443** rather than 443 for one reason: envoy is on this same machine and owns 443. Every other
component in this build gets 443 on its own host, because it has a host to itself.

```bash
sudo dnf -y install nginx

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

sudo tee /etc/nginx/conf.d/automation-gateway.conf >/dev/null <<'EOF'
upstream gateway_uwsgi {
    server 127.0.0.1:8050;
}

server {
    listen       8443 default_server ssl;
    listen  [::]:8443 default_server ssl;
    server_name  _;

    keepalive_timeout 65;

    ssl_certificate     /etc/ansible-automation-platform/gateway/gateway.cert;
    ssl_certificate_key /etc/ansible-automation-platform/gateway/gateway.key;
    ssl_protocols       TLSv1.2 TLSv1.3;
    ssl_ciphers         PROFILE=SYSTEM;
    ssl_prefer_server_ciphers on;
    ssl_session_timeout 1d;
    ssl_session_cache   shared:SSL:50m;
    ssl_session_tickets off;

    add_header Strict-Transport-Security max-age=15768000;
    add_header X-Frame-Options "DENY";
    add_header X-Content-Type-Options nosniff;

    access_log /var/log/nginx/automation-gateway.access.log main;
    error_log  /var/log/nginx/automation-gateway.error.log;

    client_max_body_size 5m;

    location = /api/eda {
        return 301 $scheme://$host/api/eda/;
    }

    location ^~ /static/ {
        alias /var/lib/ansible-automation-platform/platform/ui/static/;
    }

    location ~* /(v3|api|o)/ {
        uwsgi_pass gateway_uwsgi;
        include    /etc/nginx/uwsgi_params;
        uwsgi_param HTTP_X_REQUEST_ID $http_x_request_id;
        uwsgi_read_timeout 120s;

        error_page 504 =503 /json_503;
        error_page 502 =503 /json_503;
    }

    location = /json_503 {
        internal;
        add_header Content-Type application/json;

        if ($http_x_request_id) {
            return 503 '{"status": "error", "message": "Service Unavailable", "code": 503, "request_id": "$http_x_request_id"}';
        }
        return 503 '{"status": "error", "message": "Service Unavailable", "code": 503}';
    }

    # content-hashed assets: cache forever, and serve the pre-compressed copies
    location ~* \.(json|woff|woff2|jpe?g|png|gif|ico|svg|css|js)$ {
        root      /var/lib/ansible-automation-platform/platform/ui;
        add_header Cache-Control "public, max-age=31536000, s-maxage=31536000, immutable";
        try_files $uri =404;
        gzip_static on;
    }

    # the SPA entry point: never cache, or a deploy is invisible until a hard refresh
    location / {
        root      /var/lib/ansible-automation-platform/platform/ui;
        autoindex off;
        expires   off;
        add_header Cache-Control "public, max-age=0, s-maxage=0, must-revalidate" always;
        try_files $uri /index.html =404;
    }
}
EOF
```

Four things worth noticing:

- **`location ~* /(v3|api|o)/`** is the whole API surface: `/api/` for REST, `/o/` for OAuth, `/v3/`
  for the content endpoints hub uses. Everything else is the single-page app.
- **`try_files $uri /index.html =404`** is the SPA fallback. A browser asking for `/access/users/1`
  gets `index.html` and the app routes it client-side. Without it every URL except `/` is a 404 the
  moment someone hits refresh.
- **`gzip_static on`** is not an optimisation you can skip. The console build emits a `.gz`
  alongside every asset — `PlatformMain-<hash>.js` *and* `PlatformMain-<hash>.js.gz`. Without this
  directive nginx serves the uncompressed file and every one of those `.gz` files is dead weight on
  disk. With it, nginx hands the pre-compressed copy straight to any client that asked for gzip,
  compressing nothing at request time.
- **The two `Cache-Control` headers are opposites, deliberately.** Asset filenames contain a content
  hash, so a given URL's bytes can never change — those get `immutable` and a year. `index.html` has
  no hash and is the file that names the current assets, so it gets `must-revalidate` and zero
  seconds. Cache that one and a deploy is invisible until users hard-refresh; fail to cache the
  assets and every page load re-downloads Monaco.

```bash
sudo install -d -o root -g nginx -m 0755 /var/lib/ansible-automation-platform/platform/ui
sudo install -d -o root -g nginx -m 0755 /var/lib/ansible-automation-platform/platform/ui/static
sudo setsebool -P httpd_can_network_connect on
sudo nginx -t
sudo systemctl enable --now nginx
```

> That SELinux boolean is required and its absence is nearly invisible. nginx may not open network
> connections by default, and `uwsgi_pass` to `127.0.0.1:8050` is a network connection even on
> loopback. Skip it and both processes are `RUNNING`, both ports are listening, and every request
> 502s — with the only honest evidence in nginx's error log:
> `connect() to 127.0.0.1:8050 failed (13: Permission denied)`.

Now `collectstatic`, as **root** — `STATIC_ROOT` is a root-owned tree nginx only ever reads:

```bash
sudo bash -c 'umask 022 && aap-gateway-manage collectstatic --noinput --clear'
```

---

## 10. Start the gateway

```bash
sudo -u gateway tee /etc/ansible-automation-platform/gateway/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
log-format = [pid: %(pid)|app: -|req: -/-] %(addr) (%(user)) {%(vars) vars in %(pktsize) bytes} [%(ctime)] %(method) %(uri) => generated %(rsize) bytes in %(msecs) msecs (%(proto) %(status)) %(headers) headers in %(hsize) bytes (%(switches) switches on core %(core)) x-request-id: %(var.HTTP_X_REQUEST_ID)
uid = gateway
socket = 127.0.0.1:8050
processes = 2
buffer-size = 10240
master = true
vacuum = true
no-orphans = true
lazy-apps = true
manage-script-name = true
env = DJANGO_SETTINGS_MODULE=aap_gateway_api.settings
env = OPENSSL_armcap=0
mount = /=aap_gateway_api.wsgi:application
harakiri = 120
harakiri-graceful-timeout = 30
harakiri-graceful-signal = 6
py-call-osafterfork = true
EOF

sudo tee /etc/supervisord.d/gateway.ini >/dev/null <<'EOF'
[program:uwsgi]
command = /var/lib/ansible-automation-platform/venv/gateway/bin/uwsgi /etc/ansible-automation-platform/gateway/uwsgi.ini
user = gateway
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/ansible-automation-platform/gateway/uwsgi.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
stopwaitsecs = 15
stopsignal = KILL
stopasgroup = true
killasgroup = true
environment = OPENSSL_armcap="0"

[program:control-plane]
command = /var/lib/ansible-automation-platform/venv/gateway/bin/aap-gateway-manage start_grpc_server
user = gateway
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/ansible-automation-platform/gateway/control-plane-supervisor.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
stopwaitsecs = 5
stopsignal = KILL
stopasgroup = true
killasgroup = true
environment = OPENSSL_armcap="0"

[group:gateway-processes]
programs = uwsgi,control-plane
priority = 5
EOF

sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/ansible-automation-platform/venv/gateway/bin(/.*)?'
sudo restorecon -Rv /var/lib/ansible-automation-platform/venv/gateway/bin

sudo systemctl enable --now supervisord
sudo supervisorctl status

curl -sk https://127.0.0.1:8443/api/gateway/v1/ping/ | python3 -m json.tool
```

`dispatcherd_connected:false` is expected — the gateway's own task dispatcher isn't wired here and
isn't needed for the proxy path.

---

## 11. The console

The unified platform UI is one SPA for the *whole* platform — controller, hub and EDA included. It
discovers what exists by reading the gateway's service registry at runtime, so registering a
service makes its section appear on the next page load with no rebuild.

That is why none of the component labs that follow have a UI step: there is nothing else to build.

### Swap, first

The build bundles Monaco and all of PatternFly and asks Node for an 8 GB heap — which is more than
this VM's 8 GB of RAM once the OS has taken its share, and a great deal more than the 5 GB the
laptop-scale sizing gives it. Give it somewhere to spill either way:

```bash
sudo btrfs filesystem mkswapfile --size 6G /swapfile
sudo swapon /swapfile
swapon --show
```

> **That is not the usual `fallocate` + `mkswap` + `swapon`, because the root filesystem is
> btrfs.** Fedora Cloud Base installs on btrfs where the enterprise rebuilds give you xfs, and
> btrfs will not swap to a file that is copy-on-write, compressed, or has holes in it. Build one
> the ordinary way and the failure is at the last step, with no hint as to which of those three is
> the problem:
>
> ```
> swapon: /swapfile: swapon failed: Invalid argument
> ```
>
> `btrfs filesystem mkswapfile` sets no-COW, disables compression and preallocates in one command.
> It needs btrfs-progs 6.1 or newer, which Fedora has. On an xfs or ext4 root the classic sequence
> is still correct — check with `findmnt -no FSTYPE /` if you are not sure what you are on.

> **`free -h` already shows ~8 GB of swap before you run any of this, and it will not save you.**
> Fedora enables **zram** by default — a compressed block device backed by RAM. Swapping to it
> costs the very thing the build has run out of, so a heap that overflows physical memory does not
> get rescued by it. `swapon --show` is the command that tells you the difference: a `zram0` of
> type `partition` is the default, and `/swapfile` of type `file` is the one you just added.
> Both can be present, and the file is the one doing the work here.

### Build

```bash
sudo dnf -y install nodejs20 nodejs20-npm
node --version && npm --version

sudo install -d -o gateway -g gateway /opt/ansible-ui
sudo -u gateway git clone https://github.com/ansible/ansible-ui.git /opt/ansible-ui
sudo -u gateway git -C /opt/ansible-ui rev-parse --short HEAD
```

```bash
sudo -u gateway bash <<'EOF'
set -euo pipefail
cd /opt/ansible-ui
npm ci --ignore-scripts

cd platform
export PLATFORM_SERVER="https://192.168.1.41"
npm run build
EOF
```

> **No `--omit=dev`.** Vite, its React plugin and the TypeScript toolchain are all
> *devDependencies* — they are what performs the build, not what ships in it. Omit them and
> `npm ci` succeeds, then the build dies with `Cannot find package '@vitejs/plugin-react'`, which
> reads like a missing dependency in the repo rather than one you told npm to skip.
>
> `--ignore-scripts` skips postinstall hooks this workspace doesn't need and saves several minutes.
>
> Don't set `NODE_OPTIONS` — the package script sets its own, larger value.

`PLATFORM_SERVER` is the gateway's public URL. The built SPA makes same-origin calls, so this mostly
feeds the dev server and websocket base — but get it wrong and you have a console that loads and
then fails every request with an opaque CORS error.

### Stage it

```bash
sudo cp -a /opt/ansible-ui/platform/dist/. /var/lib/ansible-automation-platform/platform/ui/
sudo chown -R root:nginx /var/lib/ansible-automation-platform/platform/ui
sudo restorecon -Rv /var/lib/ansible-automation-platform/platform/ui
ls /var/lib/ansible-automation-platform/platform/ui/index.html
```

No nginx change, no restart, no route registration — section 9 already pointed a `root` and a
`try_files` at this directory. Filling it in is the whole deployment.

```bash
curl -sk -o /dev/null -w '%{http_code} %{content_type}\n' https://192.168.1.41:8443/
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.1.41:8443/access/users
```

---

## 12. envoy

```bash
ENVOY_VERSION=1.38.3
ARCH=$(uname -m); case $ARCH in x86_64) EARCH=x86_64 ;; aarch64) EARCH=aarch_64 ;; esac
curl -fsSL -o /tmp/envoy \
  "https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-${EARCH}"
sudo install -m 0755 /tmp/envoy /usr/local/bin/envoy
/usr/local/bin/envoy --version
```

(The asset naming quirk is real: `aarch_64`, with an underscore.)

The bootstrap declares **two static clusters and nothing else**. Every listener, route and backend
arrives over xDS as database rows:

```bash
sudo install -d -m 0755 /etc/envoy
sudo tee /etc/envoy/envoy.yaml >/dev/null <<'EOF'
node:
  id: envoy-gateway-1
  cluster: envoy

dynamic_resources:
  cds_config:
    resource_api_version: V3
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: { seconds: 5 }
      request_timeout: { seconds: 5 }
  lds_config:
    resource_api_version: V3
    api_config_source:
      api_type: REST
      transport_api_version: V3
      cluster_names: [gateway-control-plane-rest]
      refresh_delay: { seconds: 5 }
      request_timeout: { seconds: 5 }

static_resources:
  clusters:
    - name: gateway-control-plane-rest
      type: STRICT_DNS
      connect_timeout: 5s
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http_protocol_options: {}
      load_assignment:
        cluster_name: gateway-control-plane-rest
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 8443 }
      transport_socket:
        name: envoy.transport_sockets.tls
        typed_config:
          "@type": type.googleapis.com/envoy.extensions.transport_sockets.tls.v3.UpstreamTlsContext

    - name: gateway_control_plane
      type: STRICT_DNS
      connect_timeout: 5s
      typed_extension_protocol_options:
        envoy.extensions.upstreams.http.v3.HttpProtocolOptions:
          "@type": type.googleapis.com/envoy.extensions.upstreams.http.v3.HttpProtocolOptions
          explicit_http_config:
            http2_protocol_options: {}
      load_assignment:
        cluster_name: gateway_control_plane
        endpoints:
          - lb_endpoints:
              - endpoint:
                  address:
                    socket_address: { address: 127.0.0.1, port_value: 50051 }

admin:
  address:
    socket_address: { address: 127.0.0.1, port_value: 19000 }
EOF
```

The two clusters differ in one way that matters: the REST one speaks **HTTP/1.1** through nginx over
TLS; the control-plane one speaks **HTTP/2** straight to the gRPC server on loopback. gRPC requires
HTTP/2 — get `http2_protocol_options` wrong and every authorisation check fails with a protocol
error that never mentions gRPC.

Jewel's generated listener references a Lua script that rewrites gateway-facing paths down to what
each backend serves:

```bash
sudo cp /opt/jewel/tools/scripts/envoy-path-rewrite.lua \
        /etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua
sudo chmod 0644 /etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua
```

Miss it and envoy rejects the listener the moment one is created — `Invalid path: …` — and 443 never
opens.

```bash
sudo tee /etc/systemd/system/automation-gateway-proxy.service >/dev/null <<'EOF'
[Unit]
Description=Automation Gateway Proxy
After=network.target supervisord.service
Wants=supervisord.service

[Service]
Type=simple
User=gateway
Group=gateway
AmbientCapabilities=CAP_NET_BIND_SERVICE
ExecStart=/usr/local/bin/envoy -c /etc/envoy/envoy.yaml
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF

sudo tee /etc/systemd/system/automation-gateway.target >/dev/null <<'EOF'
[Unit]
Description=Automation Gateway service
After=network.target nginx.service supervisord.service automation-gateway-proxy.service
Wants=nginx.service supervisord.service automation-gateway-proxy.service

[Install]
WantedBy=multi-user.target
EOF

sudo systemctl daemon-reload
sudo systemctl enable automation-gateway.target
sudo systemctl enable --now automation-gateway-proxy

sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-port=443/tcp --add-port=80/tcp

# This node also exports /srv/ace to the other four (Lab 2). Turning on a
# default-deny firewall without this closes the courier.
for ip in 192.168.1.40 192.168.1.42 192.168.1.43 192.168.1.44; do
  sudo firewall-cmd --permanent \
    --add-rich-rule="rule family=ipv4 source address=$ip/32 port port=2049 protocol=tcp accept"
done

sudo firewall-cmd --reload
sudo firewall-cmd --list-ports
sudo firewall-cmd --list-rich-rules
```

> **Those NFS rules are not optional, and leaving them out fails in the worst possible way.** This
> is the first firewall enabled anywhere in the build, and the gateway is wearing two hats: it is
> the platform's front door *and* the machine exporting `/srv/ace`. firewalld's default zone permits
> ssh and little else, so the moment it starts, port 2049 closes and every other node's share dies.
>
> Nothing here reports that. The share is an automount, so the next process to touch `/srv/ace` —
> on `ace-controller`, in [Lab 6](06-controller.md), one lab later — simply **hangs** instead of
> failing. A `sudo ls /srv/ace` that never returns is the symptom, and it points at NFS, at the
> controller, at anything but a firewall rule you added on a different machine in the previous lab.
>
> Verify the courier still works before moving on:
>
> ```bash
> ssh ace-db "timeout 5 bash -c 'echo > /dev/tcp/ace-gateway/2049' && echo NFS-OK"
> ```

> `AmbientCapabilities=CAP_NET_BIND_SERVICE` lets a process running as `gateway` bind a port below
> 1024. Without it envoy exits immediately with a bind error, and the obvious "fix" — running it as
> root — is the wrong one.

Check the empty state before filling it:

```bash
curl -s http://127.0.0.1:19000/clusters | grep -oE '^[a-z_-]+::' | sort -u
curl -s http://127.0.0.1:19000/listeners; echo "(end)"
ss -tln | grep ':443 ' || echo "nothing on 443 — expected"
```

envoy up, polling, no listeners. In this architecture a route is a database row, not a config file.

---

## 13. Register the gateway with itself

The gateway is a service like any other, and it registers the same way. This is what opens 443.

Rows go in this order — HttpPort → ServiceCluster → ServiceNode → Service — because each references
the last:

```bash
read -s -p "gateway admin password: " GW_PW; echo
GW="https://127.0.0.1:8443/api/gateway/v1"

curl -sk -u "admin:$GW_PW" -X POST "$GW/http_ports/" -H 'Content-Type: application/json' \
  -d '{"name":"API Port","number":443,"use_https":true,"is_api_port":true}' | python3 -m json.tool | head -4

ST=$(curl -sk -u "admin:$GW_PW" "$GW/service_types/" \
     | python3 -c 'import json,sys; print({t["name"]:t["id"] for t in json.load(sys.stdin)["results"]}["gateway"])')

CL=$(curl -sk -u "admin:$GW_PW" -X POST "$GW/service_clusters/" -H 'Content-Type: application/json' \
     -d "{\"name\":\"gateway\",\"service_type\":$ST}" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])')

curl -sk -u "admin:$GW_PW" -X POST "$GW/service_nodes/" -H 'Content-Type: application/json' \
  -d "{\"name\":\"Node gateway - ace-gateway\",\"address\":\"127.0.0.1\",\"service_cluster\":$CL}" \
  -o /dev/null -w 'service_node: %{http_code}\n'

HP=$(curl -sk -u "admin:$GW_PW" "$GW/http_ports/?name=API%20Port" \
     | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["id"])')

curl -sk -u "admin:$GW_PW" -X POST "$GW/services/" -H 'Content-Type: application/json' \
  -d "{\"name\":\"gateway api\",\"api_slug\":\"gateway\",\"http_port\":$HP,\"service_cluster\":$CL,
       \"is_service_https\":true,\"service_path\":\"/\",\"service_port\":8443,
       \"order\":100,\"enable_gateway_auth\":false}" \
  -o /dev/null -w 'service: %{http_code}\n'
```

> `enable_gateway_auth: false` on the gateway's own service is not a shortcut. Every other service
> has its requests authorised by a gRPC call *into the gateway*; if the gateway did that for its own
> traffic, logging in would require already being logged in.
>
> `order: 100` makes it the catch-all. Services registered later take lower numbers and match first
> — the controller will be `order: 1`.

Watch envoy pick it up:

```bash
sleep 6
ss -tln | grep ':443 '
curl -sk https://192.168.1.41/api/gateway/v1/ping/ | python3 -m json.tool | head -5
```

> **A `404` on the first try is normal — wait five seconds and repeat.** The listener and the routes
> arrive as *separate* xDS updates, so there is a window where envoy is listening on 443 and has
> nothing to route to yet. `ss` shows the port open, `curl` returns 404, and nothing is wrong.
>
> If it is still 404 after fifteen seconds, look at what envoy actually has rather than guessing:
>
> ```bash
> curl -s http://127.0.0.1:19000/config_dump | grep -c virtual_hosts
> curl -sk -o /dev/null -w '%{http_code}\n' https://127.0.0.1:8443/
> ```
>
> nginx answering on 8443 while 443 does not tells you the service is healthy and the *registry*
> is the problem, which is a different half of the system to go looking in.

---

## Verify

```bash
systemctl is-active supervisord nginx automation-gateway-proxy
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.1.41/
curl -sk -u "admin:$GW_PW" -o /dev/null -w '%{http_code}\n' https://192.168.1.41/api/gateway/v1/me/
```

Then open **`https://192.168.1.41`** in a browser and log in as `admin`.

No certificate warning *if* you imported [Lab 3](03-internal-ca.md)'s root CA into your browser —
that is the payoff for building a real CA. Otherwise accept the interstitial; the certificate is at
`/etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt` on this host.

What you should see: **Access Management** (users, teams, organisations, roles) and **Settings**.
No Automation Execution, no Automation Content, no Automation Decisions — those are services, and
none has registered yet.

| Symptom | Cause |
|---|---|
| `401` on `/api/gateway/v1/me/`, back to login | `CSRF_TRUSTED_ORIGINS` / `FRONT_END_URL` don't match the URL you used |
| CORS error naming another origin | `PLATFORM_SERVER` was wrong at build time — rebuild the UI |
| `502` from nginx on `/api/` | `sudo supervisorctl status gateway-processes:uwsgi` |
| connection refused on 443 | no listener — the registration in section 13 didn't take |

Next: [The automation controller](06-controller.md)
