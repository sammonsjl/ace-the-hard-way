# Lab 6 — The gateway

## What you will have at the end

The platform gateway (**jewel**) built from source, running under supervisord as **two
programs** — uwsgi (REST, `127.0.0.1:8050`) and the **gRPC control plane** (`:50051`) — behind
**nginx** on 8443, with **envoy** on 443 in front of everything, polling the gateway for routes
via xDS.

```
  :443  envoy ──┬── xDS REST poll, 5s ──► nginx :8443 ──► gateway uwsgi 127.0.0.1:8050
                └── gRPC (auth checks) ──►             gateway control plane :50051
                     both clusters static; listeners and routes arrive as database rows
```

Nothing is registered yet, so envoy proxies nothing. That emptiness is the point.

## Why the gateway comes before the controller

This is the first lab that builds an actual service, and it might look out of order — surely you
build the thing that runs automation before you build the front door to it?

No, and the reason is worth understanding, because it is the shape of the whole platform. The
gateway is not a reverse proxy that you point at finished services. It is a **registry**: every
route envoy serves is a database row the gateway owns, every request envoy proxies is
authorised by a gRPC call into the gateway, and every service behind it validates identity
against a key the gateway publishes. Services join the gateway; the gateway does not discover
services.

So the gateway comes up first, empty, owning 443 — and then the controller, hub, and EDA are
each built, given an internal port, and registered into it. Build it the other way around and
you have to move the controller off 443 halfway through the tutorial, rewrite its config, and
reissue its certificate. Doing it in this order means **nothing ever moves**.

The *shape* below — paths, ports, process model, init order — is settled. What can shift under
you is the jewel *source build* itself:

> **Here be dragons.** Jewel lives at [ansible/jewel](https://github.com/ansible/jewel): no
> releases, moving daily. The end state below is right, but requirements layout and module paths
> in the source tree may drift. When the repo disagrees with a build step, the repo wins — note
> the difference.

All commands on **ace-control**.

## Layout

The gateway runs as its own **`gateway`** user (not `awx`), and its config lives in
**`/etc/ansible-automation-platform/gateway/`** — the path jewel's own `settings.py` looks for,
so we keep it, the same reasoning as AWX's `/etc/tower`:

```bash
sudo useradd --system --home-dir /var/lib/ansible-automation-platform/gateway \
             --create-home --shell /bin/bash gateway
sudo usermod -aG redis gateway      # Lab 5's socket (the gateway caches on db 4)
sudo install -d -o gateway -g gateway -m 0750 /etc/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 2775 /var/log/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 0755 /var/lib/ansible-automation-platform/venv
sudo chmod 0755 /var/lib/ansible-automation-platform

id gateway     # want: groups include redis
ls -ld /var/lib/ansible-automation-platform{,/gateway,/venv}
```

> The `venv` directory is created explicitly because the gateway's **home** is
> `/var/lib/ansible-automation-platform/gateway`, one level down — so `useradd` leaves the parent
> root-owned, and `sudo -u gateway python3.12 -m venv …/venv/gateway` fails with a bare
> `Error: [Errno 13] Permission denied: '/var/lib/ansible-automation-platform/venv'` that never
> mentions ownership.

The redis group is not optional: the settings below cache on Lab 5's socket, in a directory only
that group can enter. Miss it and the gateway starts, then fails the moment it touches the cache.
Same trick Lab 5 used for `awx`, and Labs 18–19 repeat for `pulp` and `eda`.

## Database

Same moves as Lab 4 — a role and a database:

```bash
sudo -iu postgres createuser --pwprompt gateway     # pick a password, record it
sudo -iu postgres createdb --owner=gateway gateway
sudo -iu postgres psql -c '\l gateway'              # want: gateway | gateway
```

## Extra build toolchain

The gateway does SAML federation, which pulls in `python3-saml` → `xmlsec`, and `xmlsec` compiles
against native libraries nothing else here needs. They live in **EPEL** and **CRB**
(CodeReady Builder), so enable both.

```bash
sudo dnf -y install epel-release
sudo dnf config-manager --set-enabled crb
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel python3.12-pip \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel \
  libxml2-devel xmlsec1-devel xmlsec1-openssl-devel libtool-ltdl-devel
```

**What each is for:** `libxml2-devel` + the three `xmlsec1` packages → `xmlsec`, which
`python3-saml` needs for federation; `openldap-devel` + `cyrus-sasl-devel` → `python-ldap`;
`libpq-devel`/`postgresql-devel` → `psycopg`; `libffi-devel` → `cffi`; `openssl-devel` → several
crypto builds. [Lab 8](08-awx-source.md) installs an overlapping set for AWX — the two lists are
deliberately independent, so neither lab depends on the other having run.

> **These failures all read as Python problems and none of them are.** A missing `xmlsec1-devel`
> gives you
> `Failed to build installable wheels for some pyproject.toml based projects: xmlsec`; a missing
> `openldap-devel` buries `fatal error: lber.h: No such file or directory` a hundred lines into a
> gcc invocation and then reports `Failed to build python-ldap`. In both cases the traceback names
> the Python package, never the system header. When a wheel build fails, read *up* past the pip
> summary to the first `fatal error:` line — that names the header, and the header names the
> `-devel` package.
>
> EPEL being enabled is harmless *as long as you never `dnf install uwsgi`* — see
> [Appendix A1](a1-epel-uwsgi-conflict.md). Every uwsgi in this tutorial is pip-built inside a
> venv, on purpose.

## The shared process manager

Both the gateway and (later) the controller run their processes under **one supervisord**, each
in its own program group. Set it up now, because the gateway is the first thing that needs it.

supervisord only ever *spawns* processes — it never imports anything from either application —
so unlike uwsgi it does not need to share an interpreter with the thing it runs. That is what
lets it live system-wide instead of inside a venv:

```bash
sudo dnf -y install python3.12-pip
sudo python3.12 -m pip install supervisor
ls -l /usr/local/bin/supervisord /usr/local/bin/supervisorctl
```

pip puts them in `/usr/local/bin`, which is not where a packaged supervisord lives and not
somewhere `sudo` will look. Link them into `/usr/bin`:

```bash
sudo ln -sf /usr/local/bin/supervisord  /usr/bin/supervisord
sudo ln -sf /usr/local/bin/supervisorctl /usr/bin/supervisorctl
sudo supervisorctl version    # want: a version, not "command not found"
```

> **Why the symlinks are not optional.** Rocky's `sudo` replaces `PATH` with a `secure_path` of
> `/sbin:/bin:/usr/sbin:/usr/bin` — no `/usr/local` anywhere (`sudo grep secure_path /etc/sudoers`).
> Without the links, every `sudo supervisorctl …` in this tutorial fails with
> `sudo: supervisorctl: command not found` while the binary sits there, executable, one directory
> over.
>
> It matters more than convenience. AWX restarts its own processes by shelling out to a **bare**
> `supervisorctl`, resolved from `PATH`, reading its **default** config location — no path, no
> `-c` flag, no environment variable. `/usr/bin/supervisorctl` plus `/etc/supervisord.conf` is
> exactly what that call expects. Put either somewhere clever and
> [Lab 11](11-awx-services.md) has to thread `SUPERVISOR_CONFIG_PATH` through every program's
> environment, which works right up until you forget one.

So: stock binary location, stock config path, one file per service in a drop-in directory.

```bash
sudo install -d -o root -g root -m 0755 /var/log/supervisor
sudo install -d -o root -g root -m 0755 /etc/supervisord.d
sudo install -d -o root -g root -m 0755 /var/run/supervisor
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
```

> `chown = awx:awx` on the control socket, in a file written before the `awx` user exists, looks
> like a mistake. It isn't — it's the reason AWX can restart its own processes later without
> running as root. [Lab 8](08-awx-source.md) creates that user; until then supervisord will warn
> that it can't chown the socket and carry on. If you would rather not see the warning, come back
> and add this line after Lab 8.

The unit, mirroring what a packaged supervisord ships:

```bash
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

Don't start it yet — there are no programs to run until the gateway's drop-in exists.

## Clone and build

```bash
sudo install -d -o gateway -g gateway /opt/jewel
sudo -u gateway git clone https://github.com/ansible/jewel.git /opt/jewel
sudo -u gateway git -C /opt/jewel rev-parse --short HEAD   # RECORD THIS — no tags exist to pin

sudo -u gateway python3.12 -m venv /var/lib/ansible-automation-platform/venv/gateway
sudo -u gateway bash <<'EOF'
set -euo pipefail
source /var/lib/ansible-automation-platform/venv/gateway/bin/activate
cd /opt/jewel
pip install --upgrade pip setuptools wheel setuptools_scm
# jewel splits frozen deps and git deps — install both in one resolve:
cat requirements/requirements.txt requirements/requirements_git.txt | pip install -r /dev/stdin
pip install -e .
pip install uwsgi
EOF
```

The manage entrypoint jewel installs is **`aap-gateway-manage`**. Give it a PATH wrapper and bake
in `OPENSSL_armcap=0`:

```bash
ls /var/lib/ansible-automation-platform/venv/gateway/bin/ | grep -i manage   # confirm the name
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

> **Apple Silicon war story.** On an aarch64 VM the very first `aap-gateway-manage` command you
> run exits **132** with no traceback — `rc=132`, silence. The gateway imports `cryptography`
> (for JWT and SAML) before it prints anything; OpenSSL autodetects CPU crypto features that trap
> under the hypervisor, and the process dies. The variable has to be in the wrapper (above), in
> `uwsgi.ini`, and in each supervisord program's `environment=` — all done below.
> [Lab 14](14-execution-plane.md) hits the same trap inside an EE container and fixes it a
> different way. x86_64 readers never see this.

## Settings

Jewel loads `/etc/ansible-automation-platform/gateway/settings.py` automatically — its own
`settings.py` calls `load_python_file_with_injected_context('{etc}/settings.py')`, and `{etc}` is
that directory. So a file at that path is picked up with no settings-module environment variable.

```bash
sudo -u gateway bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/ansible-automation-platform/gateway/SECRET_KEY'
sudo chmod 0400 /etc/ansible-automation-platform/gateway/SECRET_KEY

sudo -u gateway tee /etc/ansible-automation-platform/gateway/settings.py >/dev/null <<'EOF'
# Gateway override settings — local postgres, unix-socket redis, no TLS on the cache.

DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'gateway',
        'USER': 'gateway',
        'PASSWORD': 'CHANGE-ME',
        'HOST': 'localhost',
        'PORT': 5432,
    }
}

# Jewel's 'primary' cache uses a client that assumes TLS and a dedicated redis host — wrong
# for our single-box socket. Replace it with a plain django_redis client on Lab 5's socket.
# A multi-host deployment would use rediss:// plus client certificates here instead.
CACHES['primary'] = {
    'BACKEND': 'django_redis.cache.RedisCache',
    'LOCATION': 'unix:///var/run/redis/redis.sock?db=4',
    'KEY_PREFIX': 'gateway',
    'OPTIONS': {'CLIENT_CLASS': 'django_redis.client.DefaultClient'},
}
CACHES['fallback']['LOCATION'] = '/var/cache/ansible-automation-platform/gateway'

ENVOY_HOSTNAME = '127.0.0.1'
GATEWAY_SECRET_KEY_FILE = '/etc/ansible-automation-platform/gateway/SECRET_KEY'
GATEWAY_CERT_FILE = '/etc/ansible-automation-platform/gateway/gateway.cert'
GATEWAY_KEY_FILE = '/etc/ansible-automation-platform/gateway/gateway.key'
GATEWAY_PATH_REWRITE_SCRIPT_FILE = '/etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua'
STATIC_ROOT = '/var/lib/ansible-automation-platform/platform/ui/static'

GRPC_SERVER_PORT = '50051'
GRPC_SERVER_PROCESSES = 2
GRPC_SERVER_MAX_THREADS_PER_PROCESS = 10

CSRF_TRUSTED_ORIGINS = ['https://192.168.56.10']
FRONT_END_URL = 'https://192.168.56.10'

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
sudo install -d -o gateway -g gateway -m 0750 /var/cache/ansible-automation-platform/gateway
sudo vim /etc/ansible-automation-platform/gateway/settings.py   # put the real DB password in
```

Note the URLs: `https://192.168.56.10`, **no port**. envoy owns 443 from this lab onward, so the
platform's address is its final address from the moment it exists.

## The gateway's certificate

envoy terminates TLS on 443, nginx terminates it again on 8443, and the gateway hands its own
certificate to envoy when it registers a listener. All three want the same pair, signed by
[Lab 3](03-internal-ca.md)'s CA. The signing script does it in one line:

```bash
sudo /usr/local/sbin/ace-sign-service gateway /etc/ansible-automation-platform/gateway gateway ace-control cert
```

That writes `gateway.key` and `gateway.cert` — note the **`.cert`** extension, which is what
jewel's config expects; the fifth argument to the script is there for exactly this.

The `localhost` name matters too, because the gateway calls *itself* during registration. Add it
and the loopback address to the SAN:

```bash
sudo openssl x509 -in /etc/ansible-automation-platform/gateway/gateway.cert -noout -ext subjectAltName
# want: DNS:ace-control, IP:192.168.56.10
```

If your `/etc/hosts` doesn't resolve `ace-control`, re-sign with the address you actually use.
[Lab 2](02-vms.md) set this up; `getent hosts ace-control` confirms it.

## Init chain

Migrate, then create the superuser. `collectstatic` comes after nginx exists, because it writes
into a directory nginx owns.

```bash
sudo -u gateway aap-gateway-manage migrate

sudo -u gateway bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME aap-gateway-manage createsuperuser \
  --username=admin --email=admin@example.com --noinput'
```

> Pick a real password and record it — this is the account you will log into the platform with
> for the rest of the tutorial. If you get it wrong, fix it with
> `sudo -u gateway aap-gateway-manage changepassword admin`.

Then seed the **local authenticator**. A superuser row is not enough on its own: the gateway
authenticates through pluggable authenticator objects, and until one exists there is no login
backend at all — every credential, including the superuser you just made, is rejected with
`{"detail":"Invalid username/password."}`.

```bash
sudo -u gateway aap-gateway-manage authenticators --initialize
# want: "Created default local authenticator"
```

> The `authenticators` subcommand comes from `django-ansible-base`, not from jewel's own command
> set — it will not appear in jewel's `management/commands/` directory, but it is there.
>
> The failure mode if you skip it is genuinely confusing: the console renders, the password is
> right, the user exists and is a superuser, and the login form just says the credentials are
> invalid. `aap-gateway-manage shell -c "from ansible_base.authentication.models import
> Authenticator; print(Authenticator.objects.all())"` returning an empty list is the tell.

## nginx

One nginx serves every web-facing service on this box. It gets a main config with an include
directory, and each service drops in one file: the gateway now, the controller in
[Lab 12](12-nginx.md), hub and EDA in Labs 18–19.

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
```

`server_tokens off` stops nginx advertising its version in error pages and headers. The
`$connection_upgrade` map is the standard websocket dance — the controller's block needs it in
Lab 12, and it has to live in the `http` context, so it goes here.

Rocky ships a default site that also claims port 80; remove it before it collides with envoy:

```bash
sudo rm -f /etc/nginx/conf.d/default.conf
```

Now the gateway's server block:

```bash
sudo tee /etc/nginx/conf.d/automation-gateway.conf >/dev/null <<'EOF'
upstream gateway_uwsgi {
    server 127.0.0.1:8050;
}

server {
    listen       8443 default_server ssl;
    listen  [::]:8443 default_server ssl;
    server_name  _;

    ssl_certificate     /etc/ansible-automation-platform/gateway/gateway.cert;
    ssl_certificate_key /etc/ansible-automation-platform/gateway/gateway.key;
    ssl_protocols       TLSv1.2 TLSv1.3;

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
    }

    location ~* \.(json|woff|woff2|jpe?g|png|gif|ico|svg|css|js)$ {
        root      /var/lib/ansible-automation-platform/platform/ui;
        try_files $uri =404;
    }

    location / {
        root      /var/lib/ansible-automation-platform/platform/ui;
        try_files $uri /index.html =404;
    }
}
EOF
```

Two things to notice:

- **`location ~* /(v3|api|o)/`** is the entire API surface: `/api/` for REST, `/o/` for OAuth,
  `/v3/` for the content endpoints hub uses. Everything else is the single-page app.
- **`try_files $uri /index.html =404`** is the SPA fallback. A browser asking for
  `/access/users/1` gets `index.html`, and the app routes it client-side. Without this, every URL
  except `/` is a 404 the moment someone hits refresh.

That UI directory is empty until [Lab 7](07-platform-ui.md) — `/` will 404 for now, and the API
paths work regardless. Create it so nginx doesn't complain at startup:

```bash
sudo install -d -o root -g nginx -m 0755 /var/lib/ansible-automation-platform/platform/ui
sudo install -d -o root -g nginx -m 0755 /var/lib/ansible-automation-platform/platform/ui/static
sudo nginx -t                # want: syntax is ok / test is successful
sudo systemctl enable --now nginx
```

One SELinux boolean, before anything tries to use this. nginx is not allowed to open network
connections by default, and `uwsgi_pass` to `127.0.0.1:8050` is a network connection even though
both ends are on this box:

```bash
sudo setsebool -P httpd_can_network_connect on
```

> Skip it and everything *looks* right — uwsgi is listening on 8050, nginx is listening on 8443,
> both are `RUNNING` — but every request 502s and the only honest evidence is in nginx's error
> log:
>
> ```
> connect() to 127.0.0.1:8050 failed (13: Permission denied) while connecting to upstream
> ```
>
> "Permission denied" on a loopback TCP connection is almost always SELinux rather than anything
> you can see in `ls` or `ss`. [Lab 12](12-nginx.md) needs the same boolean and re-states it,
> because it also has to deal with the harder unix-socket case.

Now `collectstatic` can run — as **root**, because `STATIC_ROOT` is a root-owned tree that nginx
only ever reads:

```bash
sudo bash -c 'umask 022 && aap-gateway-manage collectstatic --noinput --clear'
```

> Run it as `gateway` and it dies with
> `PermissionError: [Errno 13] Permission denied: '.../static/admin'`.

## The gateway's supervisord programs

```bash
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
```

And the uwsgi config it points at. One socket, uwsgi protocol, localhost only — nginx is the only
thing that talks to it:

```bash
sudo -u gateway tee /etc/ansible-automation-platform/gateway/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
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
```

SELinux needs the venv's binaries labelled executable, same as
[Lab 11](11-awx-services.md) will do for AWX's:

```bash
sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/ansible-automation-platform/venv/gateway/bin(/.*)?'
sudo restorecon -Rv /var/lib/ansible-automation-platform/venv/gateway/bin
```

Start it:

```bash
sudo systemctl enable --now supervisord
sudo supervisorctl status
# want: gateway-processes:uwsgi and gateway-processes:control-plane both RUNNING

curl -sk https://127.0.0.1:8443/api/gateway/v1/ping/ | python3 -m json.tool
# want: {"status":"good", ..., "db_connected":true, ...}
# (dispatcherd_connected:false is expected — the gateway's task dispatcher isn't wired here
#  and isn't needed for the proxy path.)
```

## The lifecycle handle

Like the controller will in Lab 11, the gateway groups its dependents under a unit that runs
nothing. The gateway's is a `.target` rather than a service, because it has no process of its own
at all:

```bash
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
```

## envoy

Another real tarball moment. Pinned to a release, downloaded, checked:

```bash
ENVOY_VERSION=1.38.3
ARCH=$(uname -m); case $ARCH in x86_64) EARCH=x86_64 ;; aarch64) EARCH=aarch_64 ;; esac
curl -fsSL -o /tmp/envoy \
  "https://github.com/envoyproxy/envoy/releases/download/v${ENVOY_VERSION}/envoy-${ENVOY_VERSION}-linux-${EARCH}"
sudo install -m 0755 /tmp/envoy /usr/local/bin/envoy
envoy --version    # want: 1.38.3
```

(The asset naming quirk is real: `aarch_64`, with an underscore.)

### The bootstrap

The bootstrap declares **two static clusters** and nothing else. Everything a browser actually
reaches — listeners, routes, backends — arrives over xDS as database rows:

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

The two clusters differ in exactly one way that matters: the REST one speaks **HTTP/1.1** and
goes through nginx over TLS; the control-plane one speaks **HTTP/2** straight to the gRPC server
on loopback. gRPC requires HTTP/2 — get `http2_protocol_options` wrong there and every
authorisation check fails with a protocol error rather than anything that mentions gRPC.

### The path-rewrite script

Jewel's generated listener config references a Lua script that rewrites gateway-facing paths down
to what each backend actually serves. It ships in the jewel tree:

```bash
sudo cp /opt/jewel/tools/scripts/envoy-path-rewrite.lua \
        /etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua
sudo chmod 0644 /etc/ansible-automation-platform/gateway/envoy-path-rewrite.lua
```

Miss it and envoy rejects the listener the moment [Lab 16](16-service-registration.md) creates
one — `Invalid path: .../envoy-path-rewrite.lua` — and 443 never opens.

### The proxy service

envoy gets its own unit, separate from the gateway, so you can restart the proxy without bouncing
the application. Binding 443 as a non-root user needs one capability:

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

sudo systemctl daemon-reload
sudo systemctl enable --now automation-gateway-proxy

sudo firewall-cmd --permanent --add-port=443/tcp
sudo firewall-cmd --permanent --add-port=80/tcp
sudo firewall-cmd --reload
```

> `AmbientCapabilities=CAP_NET_BIND_SERVICE` is what lets a process running as `gateway` bind a
> port below 1024. Without it envoy exits immediately with a bind permission error, and the
> obvious "fix" — running it as root — is the wrong one.

## Verify

```bash
systemctl is-active supervisord nginx automation-gateway-proxy   # want: active × 3

# envoy found both control-plane clusters…
curl -s http://127.0.0.1:19000/clusters | grep -E 'gateway.control.plane' | head -4

# …and is polling for routes that don't exist yet:
curl -s http://127.0.0.1:19000/config_dump | python3 -c \
  'import json,sys; d=json.load(sys.stdin); print("configs:", len(d["configs"]))'

# nothing is listening on 443 yet — no listener has been registered:
curl -sk --max-time 5 https://192.168.56.10/ -o /dev/null -w '%{http_code}\n' || echo "connection refused — expected"

# but the gateway itself answers behind nginx:
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool
```

envoy up, polling, **no listeners**. In this architecture adding a route is an API call, not a
config file — [Lab 16](16-service-registration.md) makes those calls, and 443 opens then.

Next: [The platform UI](07-platform-ui.md)
