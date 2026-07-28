# Lab 6 — Configuring AWX

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
    ├── postgres.py          # database connection (Lab 3)
    ├── websocket.py         # broadcast-websocket secret
    └── cluster_host_id.py   # this node's cluster id
```

Redis needs no file — `defaults.py` already points the broker and cache at the socket from Lab 4.

All commands on **ace-control**.

## Create the directories

```bash
sudo install -d -o awx -g awx -m 0750 /etc/tower /etc/tower/conf.d
sudo install -d -o awx -g awx /var/lib/awx/projects /var/lib/awx/job_status
sudo install -d -o awx -g awx /var/log/tower
```

## SECRET_KEY

```bash
sudo -u awx bash -c 'umask 077; head -c 48 /dev/urandom | base64 -w0 > /etc/tower/SECRET_KEY'
sudo chmod 0400 /etc/tower/SECRET_KEY
sudo -u awx wc -c /etc/tower/SECRET_KEY    # want: ~64 bytes, not 0
```

## Base settings file

This is the file that turns a bare production-mode checkout into a configured one. Write the whole shape, not just the one key line — the extras below are the settings AWX's `defaults.py` leaves you to supply. Two entries are load-bearing: `SECRET_KEY`, and **`ALLOWED_HOSTS = ['*']`** — Django in production mode rejects every request with a bare `400` when `ALLOWED_HOSTS` is empty, and AWX's `defaults.py` leaves it empty. You won't notice until Lab 10, when nginx is finally in front and every `/api/` call answers `{"detail":"The request could not be understood by the server."}` while all eight services sit there running innocently. (The wildcard is safe here because nginx is the only front door, and Django still validates origins for CSRF.)

```bash
sudo -u awx tee /etc/tower/settings.py >/dev/null <<'EOF'
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

Use the `awx` database password you set in Lab 3:

```bash
sudo -u awx tee /etc/tower/conf.d/postgres.py >/dev/null <<'EOF'
DATABASES = {
    'default': {
        'ENGINE': 'django.db.backends.postgresql',
        'NAME': 'awx',
        'USER': 'awx',
        'PASSWORD': 'CHANGE-ME',   # the password from Lab 3
        'HOST': 'localhost',
        'PORT': 5432,
    }
}
EOF
sudo vim /etc/tower/conf.d/postgres.py    # replace CHANGE-ME with the real password
```

## Websocket secret and cluster id

```bash
sudo -u awx bash -c 'echo "BROADCAST_WEBSOCKET_SECRET = \"$(openssl rand -base64 32)\"" > /etc/tower/conf.d/websocket.py'

sudo -u awx tee /etc/tower/conf.d/cluster_host_id.py >/dev/null <<'EOF'
CLUSTER_HOST_ID = "ace-control"
EOF
```

## Verify

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage check'
# want: warnings only, no errors. On a source build the healthy output is
#   "System check identified some issues: WARNINGS: ... (staticfiles.W004) ...
#    System check identified 1 issue (1 silenced)."
# W004 just means the dev UI dir doesn't exist — Lab 9 builds the real UI elsewhere.
# A database or SECRET_KEY problem would be an ERROR and a traceback, not a warning.

sudo -u awx awx-manage --version
# the Lab 5 wrapper works now that /etc/tower exists — want: the version string
```

Next: [Database init](07-awx-init.md)
