# Lab 6 — Configuring AWX

## What you will have at the end

AWX's settings written by hand under `/etc/tower` — `SECRET_KEY`, the postgres connection, the broadcast-websocket secret, and the runtime directories — with `awx-manage check` passing in production mode.

## How AWX finds this config

AWX loads its `defaults.py`, then everything in `/etc/tower/conf.d/*.py` and `/etc/tower/settings.py`. A source checkout runs in **development** mode by default, so every `awx-manage` call from here on is prefixed `AWX_MODE=production` — that's what makes it read `/etc/tower` and use postgres instead of the dev sqlite.

Layout we build (mirrors the AAP 2.6 bundle):

```
/etc/tower/
├── SECRET_KEY               # 0400, awx-only
├── settings.py             # base marker; defaults cover the rest
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
sudo -u awx bash -c 'umask 077; openssl rand -base64 48 > /etc/tower/SECRET_KEY'
sudo chmod 0400 /etc/tower/SECRET_KEY
```

## Base settings file

```bash
sudo -u awx tee /etc/tower/settings.py >/dev/null <<'EOF'
# Base production settings. Package defaults apply; put overrides in conf.d/.
EOF
```

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
# want: "System check identified no issues" (warnings are fine)
```

Next: [Database init](07-awx-init.md)
