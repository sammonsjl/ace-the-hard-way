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

**Decision (documented):** TLS from day one, not plain HTTP. The bundle never ships HTTP-only, and the platform CA built here is reused for the receptor mesh (Lab 12) and the gateway (Lab 15) — skipping it now just moves the work.

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

Now restart the family and verify the socket appeared:

```bash
sudo systemctl restart automation-controller
ls -l /var/run/tower/daphne.sock    # want: a socket (type "s"), owned awx awx
```

## The lab CA

The installer's `certificate_authority` role generates its own CA, signs **every** service cert with it (nginx, receptor, redis-TLS), and installs it into the system trust store. Hand-roll the same — this one CA signs nginx today, the receptor mesh in Lab 12, and the gateway in Lab 15:

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

sudo openssl x509 -req -in /tmp/tower.csr \
  -CA /etc/tower/ca/ca.crt -CAkey /etc/tower/ca/ca.key -CAcreateserial \
  -days 825 -sha256 -out /etc/tower/tower.cert \
  -extfile <(printf "subjectAltName=DNS:ace-control,IP:192.168.56.10,IP:127.0.0.1")

rm /tmp/tower.csr
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

## Install nginx

Pin the module stream so readers get the same build:

```bash
sudo dnf -y module enable nginx:1.24
sudo dnf -y install nginx
nginx -v    # record it
```

## nginx.conf — written by hand, whole file

The installer owns the entire `nginx.conf`, so we do too. Two things to notice: **`user awx;`** — the workers must read the 660 `awx:awx` sockets and the SPA files, so they run as the service user, same as a real Tower box. And **`ssl_ciphers PROFILE=SYSTEM`** — cipher choice is delegated to Rocky's system-wide crypto policies instead of a hardcoded list.

```bash
sudo tee /etc/nginx/nginx.conf >/dev/null <<'EOF'
user awx;
worker_processes auto;
pid /run/nginx.pid;

events {
    worker_connections 1024;
}

http {
    include /etc/nginx/mime.types;
    default_type application/octet-stream;
    sendfile on;

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
            proxy_set_header Connection "upgrade";
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
}
EOF
```

## SELinux: handled, not disabled

Same philosophy as the installer — booleans and file contexts, never permissive. Three problems to solve: nginx (`httpd_t`) may not make outbound connections, may not read `var_lib_t` content, and may not connect to `var_run_t` sockets:

```bash
# the exact boolean the installer sets
sudo setsebool -P httpd_can_network_connect on

# the SPA and static files live under /var/lib — label them web content
sudo semanage fcontext -a -t httpd_sys_content_t '/var/lib/awx/public(/.*)?'
sudo restorecon -Rv /var/lib/awx/public

# the sockets — label the runtime dir so new sockets inherit a type nginx may touch
sudo semanage fcontext -a -t httpd_var_run_t '/run/tower(/.*)?'
sudo restorecon -Rv /var/run/tower
```

The fcontext rule on `/run/tower` also covers reboots: `systemd-tmpfiles` recreates the directory (Lab 8's `tower.conf`) with the label from this rule, and sockets created inside inherit it.

> **If you get a 502:** it's almost always SELinux or socket permissions. Check `sudo tail /var/log/nginx/error.log` (look for `Permission denied` on a `.sock`) and `sudo ausearch -m avc -ts recent`. Whatever you find — WHAT/WHY/FIX it into this lab.

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

**Production variant:** real installs put certs from the org's PKI (or ACME) on the front door instead of a platform-CA-signed cert; the internal CA still signs the service-to-service certs (receptor mesh, gateway). HSTS is already on — remember it pins browsers to HTTPS for six months.

Next: [Receptor](11-receptor.md)
