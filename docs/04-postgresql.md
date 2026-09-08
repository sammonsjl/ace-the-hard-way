# Lab 4 — PostgreSQL

## What this is

The platform's database server: one PostgreSQL instance on its own host, holding a separate
database for each of the four services.

## Where it fits

Every stateful thing the platform knows lives here. Job history, inventories and credentials belong
to the controller; users, teams and the service registry belong to the gateway; content metadata to
hub; rulebook activations to EDA. Four services, four databases, one server.

This is the first component you build because everything else needs it — the gateway cannot migrate
without it, and the controller cannot start.

It is also the only VM in this build that serves no HTTP at all. It has no certificate, no nginx,
no place in the gateway's registry, and no user-facing surface. It exists to be connected to, on
one port, by four hosts.

> **Why whatever Fedora ships, and not a pinned major.** The RPM installer this build replicates
> pins PostgreSQL 15 — every component sets `postgresql:15` and enables that dnf module stream.
> Fedora has no modularity to pin with, and ships one PostgreSQL major at a time. Rather than put a
> third-party repo on the critical path to recreate a version pin, we take the distro's.
>
> That is less of a departure than it looks. The platform's components need a PostgreSQL new enough
> for `scram-sha-256` and the SQL these migrations emit, not specifically 15; and the vendor is
> moving anyway — RHEL 9.8's own package list names `postgresql-18.4`. Where a version difference
> does bite, this lab says so at the point it bites.

## What you will have at the end

PostgreSQL on **ace-db**, listening on the lab network, with four roles and four databases, and
`scram-sha-256` password authentication for every remote client.

All commands on **ace-db** unless stated otherwise.

```bash
ssh ace-db
```

## Install

```bash
sudo dnf -y install postgresql-server postgresql
sudo postgresql-setup --initdb
sudo systemctl enable --now postgresql
systemctl is-active postgresql
psql --version
```

## Listen on the network

A default `initdb` binds loopback only, which was fine when everything shared a box and is useless
now. Four other machines have to reach this one:

```bash
sudo vim /var/lib/pgsql/data/postgresql.conf
```

```
listen_addresses = '192.168.1.40,localhost'
max_connections = 200
```

`listen_addresses` is deliberately **not** `'*'`. Naming the address is the difference between a
database on your lab network and a database on whatever else the host happens to be attached to.
This lab gives each VM a single interface, so `'*'` would happen to be harmless here — but it is a
habit worth keeping: add a second interface later (a management network, a storage network) and
`'*'` silently starts serving the database on it.

`max_connections` matters more here than it looks. The controller alone opens a connection per
uwsgi worker, per dispatcher process and per callback receiver; add the gateway, hub and EDA doing
the same and the default of 100 runs out during normal operation, with an error that names the
client rather than the limit.

## Password authentication

Confirm the server will hash passwords the modern way:

```bash
sudo -iu postgres psql -c "SHOW password_encryption;"
```

Then make the client rules match. The stock `initdb` ships the TCP rules as `ident`, which cannot
work for a remote client — there is no local identity to check:

```bash
sudo vim /var/lib/pgsql/data/pg_hba.conf
```

Change the loopback rules and add one per client:

```
# TYPE  DATABASE  USER      ADDRESS           METHOD
local   all       all                         peer
host    all       all       127.0.0.1/32      scram-sha-256
host    all       all       ::1/128           scram-sha-256
host    awx       awx       192.168.1.42/32   scram-sha-256
host    gateway   gateway   192.168.1.41/32   scram-sha-256
host    pulp      pulp      192.168.1.43/32   scram-sha-256
host    eda       eda       192.168.1.44/32   scram-sha-256
```

Those four `host` lines are what make this a server rather than a standalone, and each one names
exactly one database, one role, and one address. A compromised hub cannot even attempt to log into
the controller's database.

It is tempting to collapse them into a single subnet rule — `host all all 192.168.1.0/24` — and on
an isolated hypervisor network that would be a reasonable lab shortcut. **It is not one here.**
These VMs are bridged onto your home LAN, so `192.168.1.0/24` is not "the lab", it is your laptop,
your phone, your TV and every other thing on the network. A subnet rule would let any of them
attempt to authenticate to any database on this node. Write the four rules.

Apply with a **reload**, not a restart — `pg_hba.conf` is re-read on `SIGHUP`:

```bash
sudo systemctl reload postgresql
```

`listen_addresses` and `max_connections` *do* need a restart:

```bash
sudo systemctl restart postgresql
ss -tlnp | grep 5432
```

## The four databases

Each service gets its own role and its own database, owned by that role. No service can read
another's tables.

```bash
sudo -iu postgres psql <<'SQL'
CREATE USER awx      WITH PASSWORD 'CHANGE-ME-awx';
CREATE USER gateway  WITH PASSWORD 'CHANGE-ME-gateway';
CREATE USER pulp     WITH PASSWORD 'CHANGE-ME-pulp';
CREATE USER eda      WITH PASSWORD 'CHANGE-ME-eda';

CREATE DATABASE awx     OWNER awx;
CREATE DATABASE gateway OWNER gateway;
CREATE DATABASE pulp    OWNER pulp;
CREATE DATABASE eda     OWNER eda;
SQL
```

**Pick four real passwords and record them now.** Each goes into exactly one config file on exactly
one other machine, several labs apart:

| Role | Password used in | On |
|---|---|---|
| `gateway` | `/etc/ansible-automation-platform/gateway/settings.py` | [Lab 5](05-gateway.md), ace-gateway |
| `awx` | `/etc/tower/conf.d/postgres.py` | [Lab 6](06-controller.md), ace-controller |
| `pulp` | pulp's settings | [Lab 8](08-hub.md), ace-hub |
| `eda` | EDA's settings | [Lab 9](09-eda.md), ace-eda |

Confirm:

```bash
sudo -iu postgres psql -c '\l' | grep -E 'awx|gateway|pulp|eda'
```

## Firewall

```bash
sudo dnf -y install firewalld
sudo systemctl enable --now firewalld
for ip in 192.168.1.41 192.168.1.42 192.168.1.43 192.168.1.44; do
  sudo firewall-cmd --permanent --add-rich-rule="rule family=ipv4 source address=$ip/32 port port=5432 protocol=tcp accept"
done
sudo firewall-cmd --reload
sudo firewall-cmd --list-rich-rules
```

Four rules naming four addresses, rather than the one-liner `--add-service=postgresql` — that
opens 5432 to anything that can route to this node, and on a bridged network that is your whole
home LAN. The `pg_hba.conf` rules above would still refuse those connections, but there is no
reason to let them reach the authentication stage at all.

## Verify — from a client, not from here

A database that answers on localhost proves nothing. The check that matters runs on a **different
machine**. On **ace-controller**:

```bash
sudo dnf -y install postgresql
PGPASSWORD='CHANGE-ME-awx' psql -h ace-db -U awx -d awx -c 'SELECT version();'
```

That one command exercises the whole chain: name resolution (`ace-db` from `/etc/hosts`),
`listen_addresses`, the firewall, the `pg_hba.conf` rule, and the password. When it fails, the
error tells you which:

| Error | Cause |
|---|---|
| `could not translate host name "ace-db"` | `/etc/hosts` — see [Lab 2](02-vms.md) |
| `No route to host`, or a timeout | firewalld on ace-db |
| `Connection refused` | `listen_addresses` is still loopback-only, or postgres is down |
| `no pg_hba.conf entry for host …` | this client's `host` line is missing or names the wrong address, or postgres wasn't reloaded |
| `password authentication failed` | the password — everything else worked |

That table is worth internalising, because those five failures look identical from the
application's point of view later on: the service simply refuses to start.

Run the same check from **ace-gateway**, **ace-hub** and **ace-eda** with their own credentials
before moving on. Finding a broken path now costs a minute; finding it during a Django migration
costs an hour.

Next: [The platform gateway](05-gateway.md)
