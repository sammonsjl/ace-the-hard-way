# Lab 4 — Redis

## What you will have at the end

Redis from the Rocky repos, listening on a Unix socket that the `awx` user can reach. No TCP port at all.

All commands on **ace-control**.

## Install

```bash
sudo dnf -y install redis
redis-server --version    # record the version (Rocky 9 ships 6.2.x — fine; AWX needs 6+)
```

## Configure the Unix socket

AWX talks to redis over a Unix socket — that's how the real installer wires it too (socket shared between the redis and awx services). Edit the config — on Rocky 9 it's `/etc/redis/redis.conf`:

```bash
sudo vi /etc/redis/redis.conf
```

Set these (the `unixsocket` lines exist commented-out — uncomment and edit):

```
port 0                                      # no TCP — socket only, nothing to firewall
unixsocket /var/run/redis/redis.sock
unixsocketperm 770                          # owner+group only
```

`/var/run/redis` is created by the redis package's own tmpfiles.d entry (`/usr/lib/tmpfiles.d/redis.conf`) — you already know from Lab 2 why that matters after a reboot.

## Let the awx user in

Socket perm 770 means owner (`redis`) and group (`redis`) only. The awx user joins the group — exactly the installer's approach:

```bash
sudo usermod -aG redis awx
id awx        # want: groups include redis
```

## Start

```bash
sudo systemctl enable --now redis
systemctl is-active redis     # want: active
```

## Verify

```bash
# as yourself (vagrant user won't be in the redis group — this SHOULD fail):
redis-cli -s /var/run/redis/redis.sock ping     # want: Permission denied — the 770 works

# as awx (fresh login shell so the new group applies):
sudo -u awx redis-cli -s /var/run/redis/redis.sock ping    # want: PONG

# TCP really off:
ss -tlnp | grep 6379 || echo "no TCP listener — good"
```

## Optional hardening (not v1)

The real installer can also wrap redis in TLS with certs from its internal platform CA. Socket-only with group permissions is already a tighter posture for a single box; TLS-on-redis matters when redis serves remote nodes (the gateway's clustered redis in multi-node AAP). Noted for the future-labs pile.

Next: [AWX from source](05-awx-source.md)
