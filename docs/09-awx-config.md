# Lab 9 — Configuring AWX

## What you will have at the end

AWX's settings written by hand under `/etc/tower` — `SECRET_KEY`, the postgres connection, the broadcast-websocket secret, and the runtime directories — with `awx-manage check` passing in production mode.

## How AWX finds this config

AWX loads its `defaults.py`, then everything in `/etc/tower/conf.d/*.py` and `/etc/tower/settings.py`. A source checkout runs in **development** mode by default, so every `awx-manage` call from here on is prefixed `AWX_MODE=production` — that's what makes it read `/etc/tower` and use postgres instead of the dev sqlite.

Layout we build:

```
/etc/tower/
├── SECRET_KEY               # 0400, awx-only
├── settings.py             # reads SECRET_KEY from the file above
└── conf.d/
    ├── postgres.py          # database connection (Lab 4)
    ├── channels.py          # broadcast-websocket secret
    └── cluster_host_id.py   # this node's cluster id
```

Redis needs no file — `defaults.py` already points the broker and cache at the socket from Lab 5.

All commands on **ace-control**.

## Create the directories

```bash
sudo install -d -o awx -g awx -m 0750 /etc/tower /etc/tower/conf.d
sudo install -d -o awx -g awx /var/lib/awx/projects /var/lib/awx/job_status
sudo install -d -o awx -g awx /var/log/tower
```

## SECRET_KEY

```bash
sudo bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/tower/SECRET_KEY'
sudo chown root:awx /etc/tower/SECRET_KEY
sudo chmod 0640    /etc/tower/SECRET_KEY
sudo wc -c /etc/tower/SECRET_KEY              # want: ~64 bytes, not 0
sudo -u awx head -c 8 /etc/tower/SECRET_KEY   # want: 8 bytes — awx MUST be able to read it
```

> **`root:awx 0640`, not `0400`.** `/etc/tower` is root-owned ([Lab 2](02-vms.md)) so the service
> can read its configuration but never rewrite it. That means the key's *group* is what grants
> access: `settings.py` below does `open('/etc/tower/SECRET_KEY', 'rb').read()` and every AWX
> process runs as `awx`. A root-owned `0400` file looks more secure and simply cannot be read —
> you get a `PermissionError` from inside Django's settings import, which surfaces as a total
> failure to start with no obvious link to this file. The `sudo -u awx` check above is there
> precisely to catch that now rather than in Lab 11.

## Base settings file

This is the file that turns a bare production-mode checkout into a configured one. Write the whole shape, not just the one key line — the extras below are the settings AWX's `defaults.py` leaves you to supply. Two entries are load-bearing: `SECRET_KEY`, and **`ALLOWED_HOSTS = ['*']`** — Django in production mode rejects every request with a bare `400` when `ALLOWED_HOSTS` is empty, and AWX's `defaults.py` leaves it empty. You won't notice until Lab 12, when nginx is finally in front and every `/api/` call answers `{"detail":"The request could not be understood by the server."}` while all eight services sit there running innocently. (The wildcard is safe here because nginx is the only front door, and Django still validates origins for CSRF.)

```bash
sudo tee /etc/tower/settings.py >/dev/null <<'EOF'
# hand-written /etc/tower/settings.py

STATIC_ROOT = '/var/lib/awx/public/static'
PROJECTS_ROOT = '/var/lib/awx/projects'
JOBOUTPUT_ROOT = '/var/lib/awx/job_status'

SECRET_KEY = open('/etc/tower/SECRET_KEY', 'rb').read().strip()

ALLOWED_HOSTS = ['*']

# email defaults (unused until you wire notifications)
SERVER_EMAIL = 'root@localhost'
DEFAULT_FROM_EMAIL = 'webmaster@localhost'
EMAIL_SUBJECT_PREFIX = '[AWX] '
EMAIL_HOST = 'localhost'
EMAIL_PORT = 25
EMAIL_HOST_USER = ''
EMAIL_HOST_PASSWORD = ''
EMAIL_USE_TLS = False
EOF
```

(The three `*_ROOT` paths match AWX's production defaults today — we set them explicitly anyway, so an upstream default change can't silently move your data.)

## Database connection

Use the `awx` database password you set in Lab 4:

```bash
sudo tee /etc/tower/conf.d/postgres.py >/dev/null <<'EOF'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'awx',
        'USER': 'awx',
        'PASSWORD': 'CHANGE-ME',   # the password from Lab 4
        'HOST': 'localhost',
        'PORT': 5432,
    }
}
EOF
sudo vim /etc/tower/conf.d/postgres.py    # replace CHANGE-ME with the real password
```

That file holds a database password, and `sudo tee` creates it world-readable. Lock it down:

```bash
sudo chown root:awx /etc/tower/conf.d/postgres.py
sudo chmod 0640    /etc/tower/conf.d/postgres.py
```

## Websocket secret and cluster id

```bash
sudo bash -c 'echo "BROADCAST_WEBSOCKET_SECRET = \"$(openssl rand -base64 32)\"" > /etc/tower/conf.d/channels.py'

sudo tee /etc/tower/conf.d/cluster_host_id.py >/dev/null <<'EOF'
CLUSTER_HOST_ID = "ace-control"
EOF
```

Then settle the permissions on the whole tree in one pass — `settings.py` and everything in
`conf.d/` is configuration the service reads and nobody else needs to:

```bash
sudo chown root:awx /etc/tower/settings.py /etc/tower/conf.d/*.py
sudo chmod 0640     /etc/tower/settings.py /etc/tower/conf.d/*.py
sudo -u awx cat /etc/tower/conf.d/channels.py >/dev/null && echo "awx can read conf.d — good"
```

## Verify

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage check'
# want: warnings only, no errors. On a source build the healthy output is
#   "System check identified some issues: WARNINGS: ... (staticfiles.W004) ...
#    System check identified 1 issue (1 silenced)."
# W004 is permanent and expected — see below.
# A database or SECRET_KEY problem would be an ERROR and a traceback, not a warning.

sudo -u awx awx-manage --version
# the Lab 8 wrapper works now that /etc/tower exists — want: the version string
```

That `staticfiles.W004` warning about `/opt/awx/awx/ui/build` never goes away, and it is not
something to fix. There is no controller UI to build — the platform console belongs to the
gateway and you built it back in [Lab 7](07-platform-ui.md). AWX's `settings/defaults.py` still
lists that directory in `STATICFILES_DIRS` because a source checkout is *expected* to have a
front end compiled into it; a release build ships the directory containing a single empty
`index.html`, which the installer then overwrites with a redirect to the gateway.

So: one warning, permanently, on a correct build. `awx-manage check` reporting nothing else is the
result you want.

Next: [Database init](10-awx-init.md)
