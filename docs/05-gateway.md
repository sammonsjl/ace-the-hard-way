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

`https://192.168.56.11` serving a real console you can log into — with nothing in it, because no
service has registered yet.

All commands on **ace-gateway** unless stated otherwise.

```bash
ssh ace-gateway
```

---

## 1. Redis

```bash
sudo dnf -y install redis
redis-server --version
```

The socket lives in its own directory, owned by `redis`, mode `0750`:

```bash
sudo install -d -o redis -g redis -m 0750 /var/run/redis
sudo tee /etc/tmpfiles.d/redis.conf >/dev/null <<'EOF'
D /run/redis 0750 redis redis -
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
sudo vim /etc/redis/redis.conf
```

```
port 0                                # no TCP for local clients — socket only
bind 127.0.0.1 192.168.56.11
unixsocket /run/redis/redis.sock
unixsocketperm 777
dir /var/lib/redis
logfile /var/log/redis/redis.log
```

Two of those look wrong together and aren't:

- **`port 0` disables the TCP listener.** Not "bind to localhost" — off. The gateway talks to redis
  over the unix socket, which is faster and has nothing to firewall.
- **`unixsocketperm 777` looks alarming and isn't**, because the *directory* is `0750`. A process
  must be in the `redis` group to traverse `/var/run/redis` before it can even see the socket. The
  directory is the access control; the socket mode is not a second, redundant gate.

```bash
sudo systemctl enable --now redis
systemctl is-active redis
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
sudo usermod -aG redis gateway
sudo install -d -o gateway -g gateway -m 0750 /etc/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 2775 /var/log/ansible-automation-platform/gateway
sudo install -d -o gateway -g gateway -m 0755 /var/lib/ansible-automation-platform/venv
sudo install -d -o gateway -g gateway -m 0750 /var/cache/ansible-automation-platform/gateway
sudo chmod 0755 /var/lib/ansible-automation-platform

id gateway
```

The redis group is not optional — the settings below cache on a socket in a directory only that
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
sudo dnf config-manager --set-enabled crb
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel python3.12-pip \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel \
  libxml2-devel xmlsec1-devel xmlsec1-openssl-devel libtool-ltdl-devel
```

> **CRB, and *only* CRB.** Rocky's CodeReady Builder repo is off by default and holds exactly three
> things this list needs — `xmlsec1-devel`, `xmlsec1-openssl-devel` and `libtool-ltdl-devel`.
> Without it those three are the only ones that fail (`No match for argument: xmlsec1-devel`);
> everything else comes from BaseOS or AppStream. **Do not enable EPEL here.** Nothing in this
> tutorial — on any of the five machines — needs a package from it, and an enabled EPEL puts its
> `uwsgi` one careless `dnf install` away from the venv-built one this platform runs on. That
> failure is worth understanding, so [Appendix A1](a1-epel-uwsgi-conflict.md) has you enable EPEL
> deliberately, break the platform with it, and then armor the box.

---

## 4. supervisord

The gateway's two processes run under supervisord, and so — on their own machines — do the
controller's and hub's. Same pattern each time, so it is worth doing properly once.

supervisord only ever *spawns* processes; it never imports anything from the application, so unlike
uwsgi it does not need to share an interpreter with what it runs. That is what lets it live
system-wide:

```bash
sudo python3.12 -m pip install supervisor
sudo ln -sf /usr/local/bin/supervisord  /usr/bin/supervisord
sudo ln -sf /usr/local/bin/supervisorctl /usr/bin/supervisorctl
sudo which supervisord supervisorctl
sudo supervisord --version
```

> **The symlinks are not cosmetic.** Rocky's `sudo` replaces `PATH` with a `secure_path` of
> `/sbin:/bin:/usr/sbin:/usr/bin` — no `/usr/local`
> (`sudo grep secure_path /etc/sudoers`). Without them every `sudo supervisorctl` in this tutorial
> is `command not found` while the binary sits one directory over. `/usr/bin` is also where a
> packaged supervisord lives, which matters a great deal in [Lab 6](06-controller.md) — AWX shells
> out to a **bare** `supervisorctl` resolved from `PATH`, reading its **default** config path.

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
cat requirements/requirements.txt requirements/requirements_git.txt | pip install -r /dev/stdin
pip install -e .
pip install uwsgi
EOF
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

CSRF_TRUSTED_ORIGINS = ['https://192.168.56.11', 'https://ace-gateway']
FRONT_END_URL = 'https://192.168.56.11'

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
`IP:192.168.56.11` — a loopback address is in neither, so `127.0.0.1` produces a hostname
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
sudo dnf -y module enable nginx:1.24
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

The build bundles Monaco and all of PatternFly and asks Node for an 8 GB heap. This VM has 5 GB.
Give it somewhere to spill:

```bash
sudo fallocate -l 6G /swapfile
sudo chmod 600 /swapfile
sudo mkswap /swapfile
sudo swapon /swapfile
free -h | grep -i swap
```

### Build

```bash
sudo dnf -y module reset nodejs
sudo dnf -y module enable nodejs:20
sudo dnf -y install nodejs
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
export PLATFORM_SERVER="https://192.168.56.11"
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
curl -sk -o /dev/null -w '%{http_code} %{content_type}\n' https://192.168.56.11:8443/
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.56.11:8443/access/users
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
sudo firewall-cmd --reload
```

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
curl -sk https://192.168.56.11/api/gateway/v1/ping/ | python3 -m json.tool | head -5
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
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.56.11/
curl -sk -u "admin:$GW_PW" -o /dev/null -w '%{http_code}\n' https://192.168.56.11/api/gateway/v1/me/
```

Then open **`https://192.168.56.11`** in a browser and log in as `admin`.

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
