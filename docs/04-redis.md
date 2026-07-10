# Lab 4 — Redis

## What you will have at the end

Redis from the Rocky repos, listening on a Unix socket for AWX.

## Outline (to be written)

- [ ] `dnf install redis`
- [ ] Configure the Unix socket (AWX's preferred transport) + permissions
- [ ] Enable + start; verify `redis-cli -s /run/redis/redis.sock ping` → PONG

## From the real installer (2.6 RPM bundle)

- [ ] Confirmed: unix socket is the real transport (installer does the same)
- [ ] Installer also does TLS-on-redis with certs from its internal CA — note as optional hardening, not v1

Next: [AWX from source](05-awx-source.md)
