# Lab 12 — nginx front door

## What you will have at the end

The controller answering HTTPS on **8043**, with a certificate signed by
[Lab 3](03-internal-ca.md)'s CA — the API over the uwsgi unix socket, websockets over the daphne
unix socket, Django's static assets straight off disk.

```
              nginx :8043 (CA-signed cert)
                ├── /static/, /locales   → /var/lib/awx/public/static
                ├── /websocket/ …        → unix:/var/run/tower/daphne.sock   (upgrade)
                └── /                    → unix:/var/run/tower/uwsgi.sock    (uwsgi protocol)
```

All commands on **ace-control**.

## Why 8043 and not 443

envoy has owned 443 since [Lab 6](06-gateway.md). The controller is a service *behind* the
platform, not the platform itself, so it gets an internal port and never appears on 443 directly
— [Lab 16](16-service-registration.md) registers it, and from then on browsers reach it at
`https://192.168.56.10/api/controller/…` with envoy doing the routing.

On a real deployment the controller would have its own host and could happily use 443. Here all
four services share one VM, so they take internal ports: controller 8043, gateway 8443, hub 8444,
EDA 8445. That is the only reason the number is unusual, and it is why the gateway was built
first — nothing has to move later.

The nginx *base* config already exists: Lab 6 wrote `/etc/nginx/nginx.conf` with an
`include /etc/nginx/conf.d/*.conf`, and each service drops one file in. This lab writes the
controller's.

```bash
nginx -v                                 # record it — installed back in Lab 11
ls /etc/nginx/conf.d/                    # want: automation-gateway.conf, from Lab 6
```

## Tell Django about its origin

Browsers will reach the controller through envoy, so their `Origin` header says
`https://192.168.56.10` — no port. Django's CSRF check rejects any origin it hasn't been told to
trust:

```bash
sudo tee /etc/tower/conf.d/csrf.py >/dev/null <<'EOF'
CSRF_TRUSTED_ORIGINS = [
    'https://192.168.56.10',
    'https://192.168.56.10:8043',
    'https://ace-control',
]
EOF
sudo chown root:awx /etc/tower/conf.d/csrf.py
sudo chmod 0640 /etc/tower/conf.d/csrf.py
```

Both forms are listed on purpose: the platform URL for normal use, and the direct `:8043` one so
you can still debug the controller without going through the proxy.

## The certificate

Lab 3 built the CA and the signing script. One line:

```bash
sudo /usr/local/sbin/ace-sign-service tower /etc/tower awx ace-control cert
```

That writes `/etc/tower/tower.key` and `/etc/tower/tower.cert` — AWX's historical `tower` naming,
kept deliberately, because that is what the codebase and its own config still call these files.
Note the `.cert` extension again.

```bash
sudo openssl verify /etc/tower/tower.cert     # want: OK — via the system trust store
ls -l /etc/tower/tower.key                    # want: 0640 root awx
```

## Collect Django's static files

There is no SPA to serve here — the console belongs to the gateway ([Lab 7](07-platform-ui.md)).
But the *browsable API* — the thing you get by opening `/api/v2/` in a browser — is rendered by
Django and needs its stylesheets:

```bash
sudo bash -c 'umask 022 && awx-manage collectstatic --noinput --clear'
# want: "... static files copied to '/var/lib/awx/public/static'"
```

> **As root, not as `awx`** — the same rule as the gateway's `collectstatic` in
> [Lab 6](06-gateway.md), for the same reason. `STATIC_ROOT` is `root:awx` ([Lab 2](02-vms.md)):
> nginx only ever *reads* this tree and the service never writes to it at runtime, so nothing
> needs it to be service-writable. Run it as `awx` and it dies partway through with
> `PermissionError: [Errno 13] Permission denied: '/var/lib/awx/public/static/...'`, having
> already copied some of the files — which makes the retry look like it worked.
>
> `umask 022` so the copied files come out world-readable for nginx; `--clear` so a rebuild
> doesn't leave stale assets behind.

## The controller's server block

```bash
sudo tee /etc/nginx/conf.d/automation-controller.nginx.conf >/dev/null <<'EOF'
upstream uwsgi {
    server unix:/var/run/tower/uwsgi.sock;
}

upstream daphne {
    server unix:/var/run/tower/daphne.sock;
}

server {
    listen       8043 ssl;
    listen  [::]:8043 ssl;
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

    # big job payloads (bulk host imports, large launches)
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

Three details worth reading twice:

- **`location /` goes to uwsgi, not to a directory.** With no SPA in front, Django owns every
  path. That is also why there is no `try_files` fallback here and there is one in the gateway's
  block — the gateway serves a single-page app, the controller serves an API.
- **Three websocket prefixes, not one.** `/websocket/` is the direct path, `/api/websocket/` is
  what the controller's own clients use, and `/api/controller/v2/websocket/` is the path that
  arrives once envoy is routing — the gateway prefixes controller traffic with
  `/api/controller/`. Omit the third and websockets work perfectly until Lab 16, then silently
  stop.
- **`uwsgi_read_timeout 120s`** matches `harakiri = 120` in Lab 11's `uwsgi.ini`. If nginx gives
  up before uwsgi does, a slow request becomes a 504 with a worker still churning behind it.

## SELinux: handled, not disabled

A *packaged* AWX ships an SELinux policy module that quietly grants the socket allowances and the
file contexts under `/var/lib/awx`. Build from source and you get none of it. Three denials are
expected, and we write the missing policy by hand.

First, and least obvious: **SELinux has to be told that 8043 is a web port.** `httpd_t` may only
bind ports labelled `http_port_t`, and the default set is `80, 81, 443, 488, 8008, 8009, 8443,
9000`. 8443 is on that list, which is why the gateway worked without this. 8043 is not:

```bash
sudo semanage port -a -t http_port_t -p tcp 8043
sudo semanage port -l | grep '^http_port_t'      # want: 8043 now in the list
```

> Skip it and the failure is quietly misleading. `nginx -t` passes, `systemctl reload nginx`
> reports success, `systemctl is-active nginx` says `active`, and `nginx -T` shows your `listen
> 8043` directive — but nothing is listening on 8043 and every request gets a connection refused.
> The only evidence is one line in the **main** error log, not the per-service one you just
> configured:
>
> ```
> bind() to 0.0.0.0:8043 failed (13: Permission denied)
> ```
>
> A reload cannot report this as a failure because the running config is still valid; nginx simply
> keeps serving what it already had. `sudo ss -tln | grep 8043` returning nothing, on a service
> that claims to be running, is the tell.

Then the rest:

```bash
# 1. let nginx talk to upstreams
sudo setsebool -P httpd_can_network_connect on

# 2. static files under /var/lib — label them web content
sudo semanage fcontext -a -t httpd_sys_content_t '/var/lib/awx/public(/.*)?'
sudo restorecon -Rv /var/lib/awx/public
ls -ld /var/lib/awx    # want: 0755 — nginx must TRAVERSE the path too, or every file 403s
```

Third, the socket. **What breaks:**
`connect() to unix:/var/run/tower/uwsgi.sock failed (13: Permission denied)` even though the
classic permissions are right. **Why — and it's two denials, not one:** connecting to a unix
socket crosses two SELinux checks. First, `write` on the **socket inode** (labeled `var_run_t` in
our tmpfiles-created directory — a type `httpd_t` may not write). Second, `connectto` against the
*domain of the process that bound the socket*, not the socket file's label. No boolean and no
fcontext rule covers the pair:

```bash
sudo dnf -y install policycoreutils-python-utils setools-console
sudo tee /tmp/ace-nginx-upstream.te >/dev/null <<'EOF'
module ace-nginx-upstream 1.1;

require {
    type httpd_t;
    type unconfined_service_t;
    type var_run_t;
    class unix_stream_socket connectto;
    class sock_file write;
}

# nginx (httpd_t) may connect to sockets bound by our supervisord family:
# write on the socket inode, connectto on the process that bound it
allow httpd_t var_run_t:sock_file write;
allow httpd_t unconfined_service_t:unix_stream_socket connectto;
EOF
checkmodule -M -m -o /tmp/ace-nginx-upstream.mod /tmp/ace-nginx-upstream.te
semodule_package -o /tmp/ace-nginx-upstream.pp -m /tmp/ace-nginx-upstream.mod
sudo semodule -i /tmp/ace-nginx-upstream.pp
semodule -l | grep ace          # want: ace-nginx-upstream
```

Two rules — the narrow fix, and exactly the kind of thing a packaged install would have handed
you. It survives reboots, relabels, and package updates.

> **If you still get a 502:** check `sudo tail /var/log/nginx/automation-controller.error.log`. A
> `Permission denied` on a `.sock` means classic permissions — is Lab 11's setgid directory
> intact? `ls -ld /var/run/tower` should say `2775 nginx nginx`, sockets `awx nginx 660`.
>
> Don't count on `sudo ausearch -m avc -ts recent` for this one: the sock_file denial hides behind
> a `dontaudit` rule, so the audit log stays clean *while the denial keeps happening* — auditd
> running, zero AVCs, still 502. The honest tools are
> `sudo sesearch -A -s httpd_t -t var_run_t -c sock_file` (no output means the write rule is
> missing) and a `setenforce 0` bisect (works permissive, fails enforcing → SELinux, whatever the
> log says; put it back with `setenforce 1`).
>
> Never reach for `chmod 666` on the socket — uwsgi recreates it on every restart with
> `chmod-socket = 660`, so a live chmod evaporates. The directory's setgid bit is the mechanism
> that survives.

## firewalld

8043 stays **closed** to the outside. Nothing but envoy — on this same box — needs to reach it,
and leaving it shut is the point of putting a gateway in front:

```bash
sudo firewall-cmd --list-ports        # want: 443/tcp 80/tcp from Lab 6, and no 8043
```

If you want to poke the controller directly from your laptop while debugging, open it temporarily
and close it again afterwards:

```bash
# optional, and remember to undo it
sudo firewall-cmd --add-port=8043/tcp        # note: no --permanent
```

## Start it

```bash
sudo nginx -t                          # want: syntax ok / test successful
sudo systemctl reload nginx
```

`reload`, not `restart` — the gateway is served by this same nginx and there is no reason to drop
its connections.

## Verify

On the VM, with no `-k`, because Lab 3's CA is in the system trust store:

```bash
curl -s https://ace-control:8043/api/v2/ping/ | python3 -m json.tool
# want: JSON — version, active_node "ace-control", ha false
```

That command tests three separate things at once: the CA chain (no `-k`), the SAN (the hostname
matched), and the socket path (nginx reached uwsgi). If it works, TLS and the upstream wiring are
both correct.

```bash
# static assets are served off disk, not through Django:
curl -s -o /dev/null -w '%{http_code}\n' https://ace-control:8043/static/rest_framework/css/bootstrap.min.css
# want: 200

# the gateway is untouched by any of this:
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ -o /dev/null -w '%{http_code}\n'
# want: 200
```

Then a browser to `https://192.168.56.10:8043/api/v2/` — the browsable API, styled, asking you to
log in. Log in with the Lab 10 admin account: a successful login proves the CSRF fragment works.

There is no dashboard here and there should not be. The console is the platform UI, and the
controller does not appear in it until [Lab 16](16-service-registration.md).

**Production variant:** real installs put certs from the org's PKI (or ACME) on the *public* front
door — envoy's 443 — while internal CAs keep signing the service-to-service certs exactly as they
do here. HSTS is already on; remember it pins browsers to HTTPS for six months.

Next: [Receptor](13-receptor.md)
