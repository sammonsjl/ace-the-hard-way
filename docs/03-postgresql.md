# Lab 3 — PostgreSQL

## What you will have at the end

PostgreSQL 15 from the Rocky repos, running as a systemd service, with an `awx` database and user that authenticate over scram-sha-256.

> Bare metal note: no containers anywhere in this tutorial. Every service is a real systemd unit you can `systemctl status`.

## Why PostgreSQL 15

AWX's own development environment runs on PostgreSQL 15 (`quay.io/sclorg/postgresql-15-c9s` in `tools/docker-compose`), so 15 is the version its migrations and queries are actually exercised against. Rocky 9 ships 15 as a module stream, so we get it from the distro repos and pin the major version explicitly rather than inheriting whatever the default stream becomes.

All commands on **ace-control**.

## Install

```bash
sudo dnf -y module enable postgresql:15
sudo dnf -y install postgresql-server postgresql
psql --version          # want: psql (PostgreSQL) 15.x — record the exact version
```

## Initialize and start

```bash
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
systemctl is-active postgresql    # want: active
```

The data directory is `/var/lib/pgsql/data` — the distro package's default, and what the backup lab (A3) will come looking for.

## Authentication: scram-sha-256

PostgreSQL 15 defaults to scram-sha-256 for password hashing — confirm rather than assume:

```bash
sudo -iu postgres psql -c "SHOW password_encryption;"   # want: scram-sha-256
```

Now make the client-connection rules use it. Edit `/var/lib/pgsql/data/pg_hba.conf` and look at the `host` lines near the bottom. **Rocky's stock `initdb` ships them as `ident`, not `scram-sha-256`** — so you will actually see this:

```
# TYPE  DATABASE  USER  ADDRESS       METHOD
local   all       all                 peer
host    all       all   127.0.0.1/32  ident      # <- stock default, change this
host    all       all   ::1/128       ident      # <- stock default, change this
```

Change both TCP-loopback lines' METHOD to `scram-sha-256` so it matches the password auth we just confirmed:

```
# TYPE  DATABASE  USER  ADDRESS       METHOD
local   all       all                 peer
host    all       all   127.0.0.1/32  scram-sha-256
host    all       all   ::1/128       scram-sha-256
```

(`local ... peer` stays — that's what lets the `postgres` OS user administer the DB without a password. `peer` reads the OS uid straight off the Unix socket, which is why `sudo -u postgres psql` always works.)

> **Warning — leave those lines on `ident` and every TCP login fails, password or not.** `ident` (RFC 1413) asks an `identd` server on the *client* to vouch for which OS user owns the connecting socket. No VM runs `identd`, so the lookup can't complete and PostgreSQL rejects the connection *before it ever checks the password*:
>
> ```
> psql: error: connection to server at "localhost" (::1), port 5432 failed:
> FATAL:  Ident authentication failed for user "awx"
> ```
>
> Two things make this sneaky. First, `sudo -u postgres psql` keeps working the whole time (it uses the Unix socket → the `local ... peer` rule), so the DB *looks* fine. Second, `-h localhost` usually resolves to the IPv6 loopback `::1` first, so the rule that bites you is the `::1/128` line — change **both** loopback lines, not just the IPv4 one.

Apply — this is a `reload`, not a `restart`. `pg_hba.conf` is re-read on `SIGHUP`; no need to bounce the server:

```bash
sudo systemctl reload postgresql
```

## Create the AWX database and user

Pick a real password and stash it somewhere you'll find in Lab 6 (it goes into `/etc/tower/conf.d/postgres.py`):

```bash
sudo -iu postgres psql <<'SQL'
CREATE USER awx WITH PASSWORD 'CHANGE-ME';
CREATE DATABASE awx OWNER awx;
SQL
```

## Tuning

A production deployment sizes `postgresql.conf` from the box's RAM — `max_connections`, `shared_buffers`, `work_mem`, `maintenance_work_mem` — and sets `listen_addresses = '*'`, because production DBs usually serve remote nodes.

For our single-node lab, two changes in `/var/lib/pgsql/data/postgresql.conf` are worth making; the rest of Rocky's defaults are fine at this scale:

```
max_connections = 1024          # AWX's process family opens many connections
shared_buffers = 1GB            # size from RAM; ~1/8 of our 8 GB VM
```

We deliberately keep `listen_addresses` at its localhost default — our DB serves only this box. **Production variant:** on a real multi-node install, the DB is a separate host with `listen_addresses = '*'`, firewalled to the platform nodes, and pg_hba rules per node.

Restart (these two need a full restart, not a reload):

```bash
sudo systemctl restart postgresql
```

> **Warning — write the units in full: `1GB`, not `1G`.** PostgreSQL only accepts the memory-unit suffixes `B`, `kB`, `MB`, `GB`, and `TB`. A bare `1G` is an invalid value, and PostgreSQL rejects the *entire* config file when it reads it, so the postmaster exits `FATAL` before it ever opens a socket:
>
> ```
> LOG:  invalid value for parameter "shared_buffers": "1G"
> HINT: Valid units for this parameter are "B", "kB", "MB", "GB", and "TB".
> FATAL: configuration file "/var/lib/pgsql/data/postgresql.conf" contains errors
> ```
>
> The nasty part: this is fatal only on a **cold start / restart**. A live server that gets a `reload` (SIGHUP) logs the error and keeps running on the *old* value — so the typo hides until the next restart, which may be days later at a reboot. Cross-check the exact spelling before you `restart`. (`max_connections = 1024` uses no unit suffix and is never involved in this failure.)

## Verify

```bash
psql -U awx -h localhost -d awx -c '\conninfo'
# want: "You are connected to database "awx" as user "awx" ..." after the password prompt
sudo -iu postgres psql -c "SHOW max_connections;"    # want: 1024
systemctl is-enabled postgresql                     # want: enabled (survives reboot)
```

Next: [Redis](04-redis.md)
