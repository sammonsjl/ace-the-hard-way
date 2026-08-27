# Lab 4 — PostgreSQL and Redis

## What you will have at the end

One PostgreSQL container serving four databases to four services, one Redis container serving both a TCP port and a unix socket, and the run pattern every later lab repeats: a config you wrote, secrets that never land in a file a container can read, and a quadlet per service.

## Where it fits

This is the easy case, on purpose. Neither image is built from source — PostgreSQL and Redis are upstream images configured by files you mount, because building a database from source to learn about automation platforms is a detour with no destination.

That makes this the right place to learn the **run** pattern with nothing else going wrong. [Lab 5](05-gateway.md) adds the **build** pattern on top of it, and by then this half should be boring.

It is also where you meet the user-namespace boundary, which is the single most confusing thing about rootless containers and the cause of the one genuinely nasty failure in this lab.

## Passwords, and where they live

Five: one superuser and one per service.

```bash
mkdir -p ~/ace/postgresql ~/ace/redis
chmod 0700 ~/ace/postgresql ~/ace/redis

cd ~/ace/postgresql
for r in postgres awx gateway pulp eda; do
  openssl rand -base64 24 | tr -d '/+=' | head -c 24 > "pw-$r"
  chmod 0600 "pw-$r"
done
```

Now hand them to podman, which stores them outside any image or config file:

```bash
for r in postgres awx gateway pulp eda; do
  podman secret create "ace-pg-$r" ~/ace/postgresql/"pw-$r"
done
podman secret ls
```

**Want:** five secrets named `ace-pg-*`.

A podman secret is injected at run time as an environment variable or a file inside the container, and never becomes part of an image layer. The plaintext copies under `~/ace/postgresql/` stay because later labs need to read them — they are `0600` and they are why `~/ace/postgresql` is `0700`.

## PostgreSQL

Two quadlets. First the volume, because the database has to survive a container being replaced:

```bash
vim ~/.config/containers/systemd/ace-postgres-data.volume
```

```ini
[Volume]
VolumeName=ace-postgres-data
```

Then the container:

```bash
vim ~/.config/containers/systemd/ace-postgres.container
```

```ini
[Unit]
Description=ACE PostgreSQL — four databases, four roles

[Container]
ContainerName=ace-postgres
Image=docker.io/library/postgres:15
Network=host
Volume=ace-postgres-data.volume:/var/lib/postgresql/data
Volume=%h/ace/tls/extracted:/etc/pki/ca-trust/extracted:z
Secret=ace-pg-postgres,type=env,target=POSTGRES_PASSWORD
Environment=POSTGRES_INITDB_ARGS=--auth-host=scram-sha-256
Exec=postgres -c max_connections=1024 -c password_encryption=scram-sha-256 -c log_destination=stderr

[Service]
Restart=on-failure
TimeoutStartSec=120

[Install]
WantedBy=default.target
```

Five things worth reading rather than pasting:

- **`Network=host`.** Every container in this tutorial shares the host's network namespace, which is what the vendor's installer does too. It is why the port map in the README is the topology.
- **`Volume=ace-postgres-data.volume:...`** references the *other quadlet*, not a path. systemd works out that the volume unit has to start first — check with `systemctl --user cat ace-postgres` and you will see a `Requires=ace-postgres-data-volume.service` it wrote for you.
- **The trust bundle** from [Lab 3](03-internal-ca.md). Every container from here on carries this line.
- **`Secret=...,type=env`** puts the password in the environment of the process, not in this file.
- **`Exec=` overrides the image's command**, so the entrypoint still runs and still does first-time initialization. `password_encryption` is set both at initdb time (via `POSTGRES_INITDB_ARGS`) and at run time, because the first governs how the superuser's password is stored and the second governs every role you create later.

**No `UserNS=keep-id` here, and that is deliberate.** Every other container in this tutorial maps its user to your UID. The official postgres image has its own uid-999 machinery that expects the default rootless namespace, and forcing `keep-id` on it produces a permission error on the data directory that reads like a volume problem. This is the exception; Redis below shows the rule.

Start it:

```bash
systemctl --user daemon-reload
systemctl --user start ace-postgres
podman logs ace-postgres | grep -i "ready to accept"
```

### Do not put your role SQL in `/docker-entrypoint-initdb.d`

This is the obvious way to create the four roles, it is what the postgres image documents, and **it will fail here in a way that looks like success.**

Drop a `.sql` file in that directory and the entrypoint runs it on first start. But the file is on your host, owned by you, mode `0600` because it contains four passwords. Inside the container — with no `keep-id` — your UID maps to *root*, so the file appears as `root:root 0600`. PostgreSQL runs its initialization as uid **999**. It cannot read the file:

```
/usr/local/bin/docker-entrypoint.sh: running /docker-entrypoint-initdb.d/10-roles.sql
psql: error: /docker-entrypoint-initdb.d/10-roles.sql: Permission denied
```

That kills the entrypoint mid-initialization. systemd restarts the unit, the second start finds a data directory that is no longer empty, and prints:

```
PostgreSQL Database directory appears to contain a database; Skipping initialization
```

Now you have a **healthy, running PostgreSQL with none of your databases in it**, and the error that explains why was in a container that `--rm` deleted. Every subsequent failure says `role "awx" does not exist`, which sends you looking at the wrong thing entirely.

The workaround — `chmod 0644` — means world-readable passwords. The fix is to not need the file at all.

### Create the roles and databases explicitly

```bash
vim ~/ace/postgresql/ace-provision-db
```

```bash
#!/bin/bash
# ace-provision-db — one role and one database per service.
#
# Idempotent: re-running resets each role's password to the matching pw-<role>
# file. The SQL is piped into psql inside the container, so no file containing
# a password is ever readable from inside the container.
set -euo pipefail

for svc in awx gateway pulp eda; do
  pw=$(cat ~/ace/postgresql/pw-"$svc")

  podman exec -i ace-postgres psql -U postgres -v ON_ERROR_STOP=1 <<SQL
DO \$\$
BEGIN
  IF NOT EXISTS (SELECT FROM pg_roles WHERE rolname = '$svc') THEN
    CREATE ROLE $svc LOGIN;
  END IF;
END
\$\$;
ALTER ROLE $svc WITH LOGIN PASSWORD '$pw';
SQL

  if ! podman exec ace-postgres psql -U postgres -tAc \
        "SELECT 1 FROM pg_database WHERE datname='$svc'" | grep -q 1; then
    podman exec ace-postgres psql -U postgres -c "CREATE DATABASE $svc OWNER $svc;"
  fi
done
echo "provisioned"
```

```bash
chmod 0700 ~/ace/postgresql/ace-provision-db
~/ace/postgresql/ace-provision-db
```

The password crosses into the container on **stdin**, as part of a statement, and is never written anywhere a container process can open. PostgreSQL has no `CREATE ROLE IF NOT EXISTS`, hence the `DO` block; the database check is a separate query because `CREATE DATABASE` cannot run inside one.

Being able to re-run this matters more than it looks. It is how you rotate a password, and it is how you recover when a later lab has scribbled on a role.

## Redis

One server, six logical databases, and two ways in — the gateway uses a unix socket, the controller, hub and EDA use the TCP port.

```bash
mkdir -p ~/ace/redis/run
vim ~/ace/redis/redis.conf
```

```
port 6379
bind 127.0.0.1

unixsocket /run/redis/redis.sock
unixsocketperm 770

daemonize no
loglevel notice
logfile ""

save 900 1
save 300 10
save 60 10000
dir /data
```

```bash
vim ~/.config/containers/systemd/ace-redis-data.volume
```

```ini
[Volume]
VolumeName=ace-redis-data
```

```bash
vim ~/.config/containers/systemd/ace-redis.container
```

```ini
[Unit]
Description=ACE Redis — one server, six logical databases

[Container]
ContainerName=ace-redis
Image=docker.io/library/redis:7
Network=host
UserNS=keep-id
Volume=ace-redis-data.volume:/data
Volume=%h/ace/redis/redis.conf:/etc/redis/redis.conf:ro,Z
Volume=%h/ace/redis/run:/run/redis:Z
Volume=%h/ace/tls/extracted:/etc/pki/ca-trust/extracted:z
Exec=redis-server /etc/redis/redis.conf

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

```bash
systemctl --user daemon-reload
systemctl --user start ace-redis
```

**`UserNS=keep-id` is here, and PostgreSQL's absence of it is the contrast worth understanding.** A TCP port is shared automatically under `Network=host`. A unix socket is not — it is a *file*, and the gateway container in [Lab 5](05-gateway.md) reaches it by mounting the directory it lives in. `keep-id` maps the container's redis user to your UID, so the socket lands on your host owned by you:

```bash
ls -la ~/ace/redis/run/
```

**Want:** `srwxrwx--- 1 <you> <you> ... redis.sock`.

Without `keep-id` that socket would be owned by a subordinate UID out of your `/etc/subuid` range — a number that exists in no `/etc/passwd` — and the next container along would not be able to open it.

## Verify

```bash
podman exec ace-postgres psql -U postgres -tAc \
  "SELECT d.datname||' owned by '||pg_get_userbyid(d.datdba) FROM pg_database d
   WHERE datname IN ('awx','gateway','pulp','eda') ORDER BY 1;"

podman exec ace-postgres psql -U postgres -tAc \
  "SELECT rolname||' '||substring(rolpassword from 1 for 13) FROM pg_authid
   WHERE rolname IN ('awx','gateway','pulp','eda') ORDER BY 1;"

for r in awx gateway pulp eda; do
  PGPASSWORD=$(cat ~/ace/postgresql/pw-$r) podman exec -e PGPASSWORD ace-postgres \
    psql -h 127.0.0.1 -U "$r" -d "$r" -tAc "select current_user||' @ '||current_database();"
done

podman exec ace-redis redis-cli -h 127.0.0.1 ping
podman exec ace-redis redis-cli -s /run/redis/redis.sock ping
```

**Want:** four databases each owned by its own role, four roles storing `SCRAM-SHA-256`, four successful connections reporting `awx @ awx` and so on, and `PONG` twice.

One more, from your own shell rather than from inside a container — it proves the `/etc/hosts` names from [Lab 2](02-host.md) and host networking are doing what you think:

```bash
PGPASSWORD=$(cat ~/ace/postgresql/pw-awx) psql -h ace-db -U awx -d awx -tAc "select 'reached via ace-db'"
```

(If you have no `psql` on the host, skip it — nothing later depends on having one.)

Finally, both units:

```bash
systemctl --user list-units 'ace-*' --no-legend
```

**Want:** `ace-postgres.service` and `ace-redis.service` running, and their two volume units `active (exited)` — which is what a volume unit looks like when it has done its job.

Next: [The platform gateway](05-gateway.md)
