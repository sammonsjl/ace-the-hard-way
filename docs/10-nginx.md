# Lab 10 — nginx front door

## What you will have at the end

nginx terminating TLS and routing to uwsgi + daphne.

## Outline (to be written)

- [ ] `dnf install nginx`
- [ ] Self-signed cert (or plain HTTP for v1 — decide + document)
- [ ] Proxy config: `/` → uwsgi, `/websocket/` → daphne, static files direct
- [ ] Verify: `curl -k https://<control>/api/v2/ping/` answers from your laptop

## From the real installer (2.6 RPM bundle)

- [ ] Upstreams are **unix sockets**: `/var/run/tower/uwsgi.sock` AND `/var/run/tower/daphne.sock` (not TCP ports)
- [ ] Websocket location is a regex over `/websocket/`, `/api/websocket/` → daphne upstream
- [ ] TLS: `/etc/tower/tower.cert` + `tower.key`, `ssl_ciphers PROFILE=SYSTEM` (crypto-policies aware), HSTS header, `X-Frame-Options DENY`, `X-Content-Type-Options nosniff`
- [ ] `client_max_body_size` bumped (big job payloads)
- [ ] **SELinux:** `setsebool -P httpd_can_network_connect on` — the installer does exactly this; also socket file contexts
- [ ] **firewalld:** open 80 + 443
- [ ] Platform CA: the installer generates its own CA, signs every service cert with it, and adds it to the system trust store (`update-ca-trust`). Hand-roll the same: one lab CA signs nginx, receptor, and later the gateway

Next: [Receptor](11-receptor.md)
