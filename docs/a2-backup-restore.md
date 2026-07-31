# Appendix Lab A2 — Backup and restore

> Day-two operations are part of running a platform, not an afterthought — and you can't claim you have a backup until you've restored from it. Do this after Lab 17.

## What you will have at the end

A backup of your hand-built platform, a deliberately destroyed platform, and a successful restore — plus the one fact that matters more than any command here: **`SECRET_KEY` + the database *are* the platform.** Everything else you can rebuild from this tutorial.

All commands on **ace-control**.

## What actually holds state

Before backing anything up, know what you're protecting. Most of this box is rebuildable; a small part is not.

| What | Where | Lose it and… |
|---|---|---|
| **The database** | postgres `awx` | Everything is gone: jobs, inventories, credentials, instances, settings, schedules |
| **The secret key** | `/etc/tower/SECRET_KEY` (`0400 awx`) | The database survives but **every encrypted field in it is unreadable** — credentials become permanent noise. Irreplaceable |
| Service config | `/etc/tower/conf.d/*.py` | DB password, `CLUSTER_HOST_ID`, websocket secret — rewritable from Lab 9, but the DB password has to match what postgres expects |
| Hand-written config | `/etc/tower/settings.py`, `uwsgi.ini`, `supervisord.conf` | Rewritable from Labs 9 and 11 |
| The internal CA | `/etc/ansible-automation-platform/ca/` | **Back this up.** It signs every service certificate; lose it and you reissue and re-trust all of them (Lab 3) |
| Service TLS | `/etc/tower/tower.cert` + `.key`, and each service's pair | Reissuable in one line each with `ace-sign-service`, as long as the CA above survives |
| **Mesh PKI** | `/etc/receptor/tls/ca/mesh-CA.key` + `.crt` | Lose the CA key and **every node cert must be reissued** — the mesh gets rebuilt from scratch |
| Mesh node cert | `/etc/receptor/tls/ace-control.{crt,key}` | Reissuable, *if* you still have the CA key |
| **Work signing keypair** | `/etc/receptor/work_{private,public}_key.pem` | Regenerable, but the new public key must reach every execution node or all work fails verification |
| Receptor config | `/etc/receptor/receptor.conf` | Rewritable from Lab 13 |

And what you deliberately **don't** back up:

- **Redis** — a broker and cache, nothing durable. It repopulates itself.
- **The venv** (`/var/lib/awx/venv/awx`) — rebuildable from Lab 8. Keep the recorded commit SHA instead of gigabytes of site-packages.
- **Projects** (`/var/lib/awx/projects`) — SCM checkouts; a project sync recreates them.
- **Static files** (`/var/lib/awx/public/static`) — `collectstatic` recreates them (Lab 9).
- **`/var/lib/receptor`** — in-flight work units only. Nothing there outlives a job.

## Take the backup

Two artifacts: a database dump and a config archive. Give each a home the right user can write, and keep them out of world-readable space:

```bash
TS=$(date +%Y%m%d-%H%M%S); echo "backup stamp: $TS"

sudo install -d -m 0755 /var/backups/ace
sudo install -d -m 0700 -o postgres -g postgres /var/backups/ace/db
sudo install -d -m 0700 /var/backups/ace/etc
```

`/var/backups/ace` is `0755` only so the `postgres` user can traverse into its own `0700` subdirectory — `pg_dump` runs as `postgres` and writes there itself.

**The database** — custom format (`-Fc`): compressed, and it lets `pg_restore` be selective later. Nothing needs stopping; `pg_dump` takes a consistent snapshot of a running database:

```bash
sudo -iu postgres pg_dump -Fc -f /var/backups/ace/db/awx-$TS.dump awx
```

**The config** — `/etc/tower` and `/etc/receptor` together, preserving permissions and numeric ownership, because `SECRET_KEY` being `0400 awx` is part of what you're backing up:

```bash
sudo tar -czf /var/backups/ace/etc/config-$TS.tar.gz --numeric-owner -p /etc/tower /etc/receptor
sudo ls -l /var/backups/ace/db /var/backups/ace/etc
```

`tar` prints `Removing leading '/' from member names` — expected, and it's why the restore below uses `-C /`.

## Verify the backup before you trust it

An unverified backup is a rumour. Check both artifacts are readable and hold what you think:

```bash
sudo pg_restore -l /var/backups/ace/db/awx-$TS.dump | grep -c 'TABLE DATA'
# want: a few hundred — real table data, not just a schema

sudo tar -tzvf /var/backups/ace/etc/config-$TS.tar.gz | grep -E 'SECRET_KEY|mesh-CA.key|work_private_key'
# want: all three listed — and SECRET_KEY showing -r-------- , its mode preserved
```

If `SECRET_KEY` isn't in that archive, stop and fix it now. It's the one file you cannot regenerate.

## Break it

Stop the controller family. Receptor goes down with it — Lab 13's unit has `PartOf=automation-controller.service`:

```bash
sudo systemctl stop automation-controller
systemctl is-active automation-controller receptor    # want: inactive, inactive
```

Postgres won't drop a database that still has connections, so clear any stragglers first:

```bash
sudo -iu postgres psql -c "SELECT pg_terminate_backend(pid) FROM pg_stat_activity WHERE datname = 'awx';"
sudo -iu postgres dropdb awx
sudo -iu postgres psql -c '\l' | grep -c 'awx'    # want: 0 — really gone
```

Confirm the platform is genuinely broken, not merely stopped:

```bash
sudo -u awx awx-manage list_instances
# want: an OperationalError — FATAL: database "awx" does not exist
```

## Restore

Recreate the database owned by `awx`, then load the dump:

```bash
sudo -iu postgres createdb -O awx awx
sudo -iu postgres pg_restore -d awx /var/backups/ace/db/awx-$TS.dump
```

Silence means success. Two things worth understanding:

- **`dropdb` did not drop the `awx` role.** Roles live in the cluster, not inside a database, so the login and its password survived — which is why nothing in `/etc/tower/conf.d/postgres.py` needed touching. Rebuild the whole *cluster* and you're back at Lab 4's `CREATE USER`.
- **Ownership comes back from the dump.** `pg_restore` runs as superuser `postgres` and reassigns objects to `awx`, because that role still exists.

If you also lost the config — the real disaster, not this drill — restore it before starting anything:

```bash
sudo tar -xzf /var/backups/ace/etc/config-$TS.tar.gz -C / --numeric-owner -p
sudo ls -l /etc/tower/SECRET_KEY    # want: -r-------- 1 awx awx
```

Then bring the family back:

```bash
sudo systemctl start automation-controller
systemctl is-active automation-controller receptor    # want: active, active
sudo -u awx awx-manage list_instances                 # want: ace-control, with capacity
```

## Prove it — an untested restore is not a restore

`list_instances` answering only proves the schema loaded. Run real work: in the UI (`https://192.168.56.10`), launch **Demo Job Template**. It should reach **Successful** on `Execution Node: ace-exec`, exactly as in [Lab 17](17-smoke-test.md).

That one job exercises the restored database, the surviving `SECRET_KEY`, the mesh certs, and the work-signing keypair together.

## The `SECRET_KEY` lesson, demonstrated

The table above claims `SECRET_KEY` is irreplaceable. Prove it instead of believing it.

**Plant a canary first.** In the UI, edit **Demo Credential** and give it a password — something memorable like `canary-1234`. AWX stores it encrypted, keyed by `SECRET_KEY`. Confirm it reads back:

```bash
sudo -u awx awx-manage shell -c "
from awx.main.models import Credential
from awx.main.utils import decrypt_field
c = Credential.objects.get(name='Demo Credential')
print('stored as:', str(c.inputs.get('password'))[:11])
print('decrypts correctly:', decrypt_field(c, 'password') == 'canary-1234')"
# want: stored as: $encrypted$   and   decrypts correctly: True
```

**Now the experiment.** Move the real key aside, drop in a different one, and ask the same question:

```bash
sudo cp -a /etc/tower/SECRET_KEY /root/SECRET_KEY.real
sudo bash -c 'umask 377; head -c 48 /dev/urandom | base64 -w0 > /etc/tower/SECRET_KEY'
sudo systemctl restart automation-controller
```

Re-run the check. The database is untouched and perfectly healthy — every row still there — but the credential no longer decrypts, and any job using it fails. Nothing in the API, the logs, or `list_instances` points at a *backup* problem; it reads like corruption.

Put the real key back:

```bash
sudo install -o awx -g awx -m 0400 /root/SECRET_KEY.real /etc/tower/SECRET_KEY
sudo systemctl restart automation-controller
```

Re-run the check once more — `decrypts correctly: True`. **That's the whole lesson:** a database dump without its `SECRET_KEY` is a backup of everything except the secrets, and you won't find out until you need them.

## If you've done the platform labs

Each platform service adds state in exactly the same two shapes — a database, plus a secret you cannot regenerate:

| Service | Database | Irreplaceable secret | Other state |
|---|---|---|---|
| Gateway | `gateway` | `/etc/ansible-automation-platform/gateway/SECRET_KEY` | `settings.py`, `gateway.crt`/`.key` |
| Hub | `pulp` | `/etc/pulp/certs/database_fields.symmetric.key` | `/etc/pulp/settings.py`, uploaded content under `/var/lib/pulp/media` |
| EDA | `eda` | `/etc/eda/SECRET_KEY` | `/etc/eda/settings.yaml` |

Same pattern: `pg_dump` each database, archive each config directory with `--numeric-owner -p`, and treat those three key files exactly the way you treat `/etc/tower/SECRET_KEY`. The platform UI's static files (`/var/lib/ansible-automation-platform/platform/ui`) are rebuildable from Lab 7 — don't bother.

Back to the [README](../README.md)
