# Lab 5 — Redis

## What you will have at the end

Redis from the Rocky repos, listening on a Unix socket in a directory only members of the
`redis` group can enter. No TCP port at all.

All commands on **ace-control**.

## Install

```bash
sudo dnf -y install redis
redis-server --version    # record the version (Rocky 9 ships 6.2.x — fine; we need 6+)
```

## Create the socket directory

The socket lives in its own directory, owned by `redis`, mode `0750`:

```bash
sudo install -d -o redis -g redis -m 0750 /var/run/redis
```

`/var/run` is a tmpfs — it is empty after every reboot. A directory you create by hand is gone
the moment the VM restarts, and redis then fails to start with a bind error that says nothing
about the real problem. Write a tmpfiles.d entry so systemd recreates it at boot:

```bash
sudo tee /etc/tmpfiles.d/redis.conf >/dev/null <<'EOF'
D /run/redis 0750 redis redis -
EOF
sudo systemd-tmpfiles --create
ls -ld /var/run/redis    # want: drwxr-x--- redis redis
```

> `D` rather than `d`: `D` empties the directory on boot as well as creating it. A stale socket
> file from an unclean shutdown is exactly the kind of thing that makes a service refuse to start
> once and then work fine after you delete something by hand and never learn why.
>
> And `/run`, not `/var/run`, in the tmpfiles entry — they are the same directory, but systemd
> calls the older spelling a "legacy directory" and prints a rewrite warning on every
> `systemd-tmpfiles` run. Same applies to every tmpfiles entry in this tutorial.

SELinux labels a directory by its path, and one you create by hand inherits the wrong context:

```bash
sudo restorecon -Rv /var/run/redis
```

## Configure the socket

Redis talks to its clients over a Unix socket rather than TCP — the socket is shared between the
redis, awx, and gateway services, and there is nothing listening on the network to firewall.

```bash
sudo vim /etc/redis/redis.conf
```

Set these (the `unixsocket` lines exist commented out — uncomment and edit):

```
port 0                                # no TCP at all — socket only, nothing to firewall
bind 127.0.0.1
unixsocket /run/redis/redis.sock
unixsocketperm 777
dir /var/lib/redis
logfile /var/log/redis/redis.log
```

Two of those look wrong together and aren't:

- **`port 0` disables the TCP listener entirely.** Not "bind to localhost" — off. `bind 127.0.0.1`
  stays anyway so that anything which later re-enables a port can't accidentally publish it.
- **`unixsocketperm 777` looks alarming and isn't**, because the *directory* is `0750`. A process
  must be in the `redis` group to traverse `/var/run/redis` before it can even see the socket
  file, let alone open it. The directory is the access control; the socket mode isn't a second,
  redundant gate. Do it the other way around — `0755` directory, `770` socket — and you get the
  same security with worse error messages.

## Let the awx user in

```bash
sudo usermod -aG redis awx
id awx        # want: groups include redis
```

[Lab 6](06-gateway.md) does the same for the `gateway` user, and Labs 18–19 for `pulp` and `eda`.
Every service that caches in redis joins this group. It is not a workaround — it is the access
model.

## Start

```bash
sudo systemctl enable --now redis
systemctl is-active redis     # want: active
```

## Verify

```bash
# as yourself — the vagrant user isn't in the redis group, so this SHOULD fail:
redis-cli -s /var/run/redis/redis.sock ping     # want: Permission denied

# as awx:
sudo -u awx redis-cli -s /var/run/redis/redis.sock ping    # want: PONG

# TCP really off:
ss -tlnp | grep 6379 || echo "no TCP listener — good"
```

Survives a reboot — the check that matters, because the socket directory is on tmpfs:

```bash
sudo reboot
# wait, then back in:
ls -ld /var/run/redis                                       # want: still drwxr-x--- redis redis
systemctl is-active redis                                   # want: active
sudo -u awx redis-cli -s /var/run/redis/redis.sock ping     # want: PONG
```

> **`Opening Unix socket: bind: Permission denied` on start.** Redis is running *as* `redis` and
> still can't create its own socket, which makes no sense until you look at the directory. Either
> it doesn't exist (tmpfiles entry missing, or you made it by hand and then rebooted), or it
> exists with the wrong SELinux context (made by hand, never `restorecon`-ed). Check both with
> `ls -ldZ /var/run/redis` — you want `redis redis` and a context containing `redis_var_run_t`.
> `sudo systemd-tmpfiles --create && sudo restorecon -Rv /var/run/redis` fixes both.

Next: [The gateway](06-gateway.md)
