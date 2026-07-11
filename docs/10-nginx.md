# Lab 10 — nginx front door

## What you will have at the end

nginx terminating TLS with a certificate signed by your own **lab CA**, fronting everything: the SPA at `/`, the API over the uwsgi unix socket, websockets over the daphne unix socket. One URL from your laptop: `https://192.168.56.10`.

```
laptop ── https://192.168.56.10 (lab-CA-signed cert)
            │
          nginx
            ├── /            → /var/lib/awx/public/ui       (the SPA from Lab 9)
            ├── /static/     → /var/lib/awx/public/static   (Django static)
            ├── /websocket/  → unix:/var/run/tower/daphne.sock  (upgrade)
            └── /api/        → unix:/var/run/tower/uwsgi.sock   (uwsgi protocol)
```

**Decision (documented):** TLS from day one, not plain HTTP. The bundle never ships HTTP-only, and the web CA built here signs the gateway's front door later (Lab 15) — skipping it now just moves the work. (The receptor mesh gets its **own** root CA in Lab 11, exactly like the bundle.)

All commands on **ace-control**.

## Match the bundle: daphne moves to a unix socket

The bundle's nginx upstreams are **both unix sockets** — `uwsgi.sock` and `daphne.sock`, no TCP. Lab 8 ran daphne on `127.0.0.1:8051` to keep first bring-up debuggable with curl; now that it's proven, switch it to the socket:

```bash
sudo vim /etc/tower/supervisord.conf
```

Change the `[program:daphne]` command line to:

```ini
command=/var/lib/awx/venv/awx/bin/daphne -u /var/run/tower/daphne.sock awx.asgi:channel_layer
```

Don't restart yet — one more config change first.

## Tell Django about its new origin

Logging in through nginx means the browser POSTs with `Origin: https://192.168.56.10`. Django's CSRF check rejects any origin it hasn't been told to trust, so the UI login would fail with a 403 the moment nginx is up. Add the fragment now:

```bash
sudo -u awx tee /etc/tower/conf.d/csrf.py >/dev/null <<'EOF'
CSRF_TRUSTED_ORIGINS = ['https://192.168.56.10', 'https://ace-control']
EOF
```

Now restart the family and verify the socket appeared (note it may take a while for the socket to appear):

```bash
sudo systemctl restart automation-controller
ls -l /var/run/tower/daphne.sock    # want: srw------- (or similar) owned awx nginx — group "nginx" via the Lab 8 setgid dir
```

## The lab CA

The installer's `certificate_authority` role generates a CA for the platform's **web certs** and installs it into the system trust store. Hand-roll the same — this CA signs nginx today and the gateway's front in Lab 15. (One correction from reading the actual bundle: the receptor mesh is NOT signed by this CA — the `receptor` role creates its own dedicated root CA with `receptor --cert-init`. Lab 11 does the same.)

```bash
sudo install -d -m 0700 /etc/tower/ca
sudo openssl genrsa -out /etc/tower/ca/ca.key 4096
sudo openssl req -x509 -new -key /etc/tower/ca/ca.key -sha256 -days 3650 \
  -subj "/CN=ACE Lab CA" -out /etc/tower/ca/ca.crt
```

Sign the web cert into the bundle's paths (`/etc/tower/tower.cert` + `tower.key` — tower legacy, kept deliberately). The SANs cover every name this box answers to:

```bash
sudo openssl genrsa -out /etc/tower/tower.key 2048
sudo chmod 0600 /etc/tower/tower.key

sudo openssl req -new -key /etc/tower/tower.key \
  -subj "/CN=ace-control" -out /tmp/tower.csr

printf "subjectAltName=DNS:ace-control,IP:192.168.56.10,IP:127.0.0.1\n" | sudo tee /tmp/tower_ext.cnf >/dev/null

sudo openssl x509 -req -in /tmp/tower.csr \
  -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key -CAcreateserial \
  -days 825 -sha256 -out /etc/tower/tower.cert \
  -extfile /tmp/tower_ext.cnf

sudo rm -f /tmp/tower.csr /tmp/tower_ext.cnf
```

Install the CA into the system trust, exactly like the installer's `update-ca-trust` step:

```bash
sudo cp /etc/tower/ca/ca.crt /etc/pki/ca-trust/source/anchors/ace-lab-ca.crt
sudo update-ca-trust
```

Now `curl` **on the VM** trusts the platform without `-k`. Your laptop doesn't know this CA — either import `ca.crt` there or use `curl -k` from outside.

## Collect Django's static files

The SPA is self-contained, but the browsable API (`/api/v2/` in a browser) needs Django's static assets. The bundle serves them straight from disk, so populate `STATIC_ROOT` (defaults to `/var/lib/awx/public/static`):

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage collectstatic --noinput'
# want: "... static files copied to '/var/lib/awx/public/static'"
```

## nginx: already installed (Lab 8)

The package went in back in Lab 8 — only there so the `nginx` system user/group existed before the socket directory was created. Confirm it's still there:

```bash
nginx -v    # record it
```

## nginx.conf — the base file, no `user` override

**Match the bundle:** the installer's generic `nginx` role writes the *whole* `nginx.conf`, but it never sets a `user` directive — nginx keeps running as its compiled-in default, which on Rocky's package is `nginx`. That's deliberate: `nginx` (not `awx`) is the one reading the sockets, and Lab 8 already set up `/var/run/tower` as `nginx:nginx` with setgid so awx's sockets land in the `nginx` group. Per-service server blocks are a **separate concern**, dropped into `conf.d/` by each component's own role — so this file only carries the shared plumbing: mime types, logging, and the `$http_upgrade` map that websocket proxying needs.

```bash
sudo tee /etc/nginx/nginx.conf >/dev/null <<'EOF'
worker_processes auto;
error_log /var/log/nginx/error.log warn;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    server_tokens off;

    log_format main '$remote_addr - $remote_user [$time_local] "$request" '
                     '$status $body_bytes_sent "$http_referer" "$http_user_agent"';
    access_log /var/log/nginx/access.log main;

    # lets a websocket Upgrade header pass through the reverse proxy
    map $http_upgrade $connection_upgrade {
        default upgrade;
        ''      close;
    }

    sendfile on;
    tcp_nopush on;
    tcp_nodelay on;
    types_hash_max_size 4096;

    include /etc/nginx/conf.d/*.conf;
}
EOF
```

## automation-controller.nginx.conf — the controller's own snippet

This is the `conf.d/` file the `automationcontroller` role would drop — everything specific to *this* service (upstreams, TLS, routes) lives here, not in the shared `nginx.conf`. **`ssl_ciphers PROFILE=SYSTEM`** delegates cipher choice to Rocky's system-wide crypto policy instead of a hardcoded list.

```bash
sudo tee /etc/nginx/conf.d/automation-controller.nginx.conf >/dev/null <<'EOF'
upstream uwsgi {
    server unix:/var/run/tower/uwsgi.sock;
}

upstream daphne {
    server unix:/var/run/tower/daphne.sock;
}

# everything on 80 bounces to TLS
server {
    listen 80 default_server;
    server_name _;
    return 301 https://$host$request_uri;
}

server {
    listen 443 ssl http2 default_server;
    server_name _;

    ssl_certificate     /etc/tower/tower.cert;
    ssl_certificate_key /etc/tower/tower.key;
    ssl_ciphers         PROFILE=SYSTEM;

    add_header Strict-Transport-Security max-age=15768000;
    add_header X-Frame-Options DENY;
    add_header X-Content-Type-Options nosniff;

    # big job payloads (bulk host imports, large launches)
    client_max_body_size 100m;

    # the SPA, with client-side-routing fallback
    location / {
        root /var/lib/awx/public/ui;
        try_files $uri $uri/ /index.html;
    }

    # Django static (browsable API)
    location /static/ {
        alias /var/lib/awx/public/static/;
    }

    # websockets → daphne (regex over both prefixes, like the bundle)
    location ~* /(websocket|api/websocket)/ {
        proxy_pass http://daphne;
        proxy_http_version 1.1;
        proxy_set_header Upgrade $http_upgrade;
        proxy_set_header Connection $connection_upgrade;
        proxy_set_header Host $host;
        proxy_set_header X-Forwarded-For $proxy_add_x_forwarded_for;
        proxy_set_header X-Forwarded-Proto https;
    }

    # API → uwsgi, speaking the uwsgi protocol (not HTTP proxying)
    location /api/ {
        include /etc/nginx/uwsgi_params;
        uwsgi_pass uwsgi;
        uwsgi_read_timeout 120s;    # matches harakiri in uwsgi.ini
        uwsgi_param HTTP_X_FORWARDED_FOR $proxy_add_x_forwarded_for;
        uwsgi_param HTTP_X_FORWARDED_PROTO https;
    }
}
EOF
```

## SELinux: handled, not disabled

Verified against the bundle, and the split matters: the installer's `nginx` role sets exactly **one** thing — the `httpd_can_network_connect` boolean. Everything else (socket `connectto` allowances, file contexts for `/var/lib/awx`) comes from the **automation-controller RPM's own SELinux policy module**, which a from-source build doesn't have. So on this box, three denials are *expected*, and we replace the RPM policy by hand:

```bash
# 1. the exact boolean the installer sets
sudo setsebool -P httpd_can_network_connect on

# 2. the SPA and static files live under /var/lib — label them web content
#    (this is the RPM policy's file-context equivalent)
sudo semanage fcontext -a -t httpd_sys_content_t '/var/lib/awx/public(/.*)?'
sudo restorecon -Rv /var/lib/awx/public
ls -ld /var/lib/awx    # want: 0755 (Lab 2) — nginx must TRAVERSE the path too,
                       # or every file 403s with "stat() failed (13: Permission denied)"
```

Third: the socket. **WHAT breaks:** `connect() to unix:/var/run/tower/uwsgi.sock failed (13: Permission denied)` even though classic permissions are right. **WHY:** SELinux's `connectto` check is against the *domain of the process that bound the socket* (uwsgi runs unconfined under our hand-rolled supervisord), not the socket file's label — so no boolean and no fcontext rule can allow it. The RPM ships a policy module for this; we write the minimal equivalent:

```bash
sudo dnf -y install policycoreutils-python-utils setools-console
sudo tee /tmp/ace-nginx-upstream.te >/dev/null <<'EOF'
module ace-nginx-upstream 1.0;

require {
    type httpd_t;
    type unconfined_service_t;
    class unix_stream_socket connectto;
}

# nginx (httpd_t) may connect to sockets bound by our supervisord family
allow httpd_t unconfined_service_t:unix_stream_socket connectto;
EOF
checkmodule -M -m -o /tmp/ace-nginx-upstream.mod /tmp/ace-nginx-upstream.te
semodule_package -o /tmp/ace-nginx-upstream.pp -m /tmp/ace-nginx-upstream.mod
sudo semodule -i /tmp/ace-nginx-upstream.pp
```

This is a one-rule module — the narrow, production-grade fix, and philosophically identical to what the RPM does. It survives reboots, relabels, and package updates (`semodule -l | grep ace` to confirm it's loaded).

> **If you still get a 502:** check `sudo tail /var/log/nginx/error.log` (a `Permission denied` on a `.sock` means classic perms — is the Lab 8 setgid dir intact? `ls -ld /var/run/tower` should say `2775 nginx nginx`, sockets `awx nginx 660`) and `sudo ausearch -m avc -ts recent` for anything SELinux still blocks. Never reach for `chmod 666` on the socket — uwsgi recreates it on every restart with `chmod-socket = 660`, so live chmods silently evaporate. The dir's setgid bit + group `nginx` is the mechanism that survives restarts.

## firewalld: open the front door

The installer's `firewall` role opens 80 + 443 on controller nodes. The bento box may ship without firewalld running — install and enable it, then open the ports:

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
sudo firewall-cmd --permanent --add-service=http --add-service=https
sudo firewall-cmd --reload
sudo firewall-cmd --list-services    # want: ... http https ssh ...
```

## Start it

```bash
sudo nginx -t                          # want: syntax ok / test successful
sudo systemctl enable --now nginx
```

## Verify

On the VM — no `-k`, because the lab CA is in the system trust:

```bash
curl -s https://192.168.56.10/api/v2/ping/ | python3 -m json.tool
# want: JSON — version, active_node "ace-control", ha false
```

From your **laptop**:

```bash
curl -sk https://192.168.56.10/api/v2/ping/ | python3 -m json.tool   # same JSON
curl -skI https://192.168.56.10/ | grep -i strict-transport            # HSTS header present
```

Then the real test — browser to `https://192.168.56.10` (accept the lab-CA warning, or import `ca.crt`):

- the SPA login page loads at `/` — Lab 9's build is being served;
- log in as the Lab 7 admin — a successful login proves the CSRF fragment works;
- the dashboard renders live — no red websocket errors in the browser console proves the daphne socket routing works.

**Production variant:** real installs put certs from the org's PKI (or ACME) on the front door instead of a platform-CA-signed cert; internal CAs still sign the service-to-service certs (the web CA for components, the mesh CA for receptor). HSTS is already on — remember it pins browsers to HTTPS for six months.

Next: [Receptor](11-receptor.md)
