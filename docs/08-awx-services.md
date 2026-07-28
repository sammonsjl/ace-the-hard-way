# Lab 8 — Running the services

## What you will have at the end

Every AWX process running under **supervisord**, with one systemd unit at the top, and every config written by hand. `list_instances` finally shows real capacity and a version.

```
systemd ── automation-controller.service ── supervisord ──┬── uwsgi             (API, WSGI, unix socket)
                                                   ├── daphne            (websockets/ASGI, 127.0.0.1:8051)
                                                   ├── dispatcher        (task engine)
                                                   ├── callback-receiver (job events)
                                                   ├── wsrelay           (websocket relay)
                                                   └── ws-heartbeat      (instance heartbeat)
```

rsyslog (two more programs) is added at the end, once the core is proven. All commands on **ace-control**.

## Install supervisor + uwsgi in the venv

Both must live in the AWX venv, married to our interpreter — never EPEL builds (see [Appendix A1](a1-epel-uwsgi-conflict.md)):

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/pip install supervisor uwsgi
```

## Install nginx (package only — config comes in Lab 10)

**Note the ownership:** the socket directory is `nginx:nginx`, not `awx:awx` — nginx (not awx) is the one *reading* `uwsgi.sock`/`daphne.sock`, and a `setgid` bit on the directory makes every socket awx creates inherit the `nginx` group automatically. That only works if the `nginx` system user/group already exists, so pull the package in now — nginx itself isn't configured or started until Lab 10:

```bash
sudo dnf -y module enable nginx:1.24
sudo dnf -y install nginx
sudo usermod -aG nginx awx    # awx needs group-write on the setgid socket dir to create sockets there
```

## Socket directory (survives reboot)

`/var/run` is tmpfs — wiped on reboot. A `tmpfiles.d` entry recreates the socket dir every boot. Owner is `nginx:nginx`, mode `2775` — the leading `2` is the setgid bit, so files awx creates inside still come out group `nginx`:

```bash
sudo tee /etc/tmpfiles.d/tower.conf >/dev/null <<'EOF'
d /run/tower 2775 nginx nginx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tower.conf
sudo install -d -o root -g root -m 0755 /var/log/supervisor
```

## uwsgi.ini

```bash
sudo -u awx tee /etc/tower/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
socket = /var/run/tower/uwsgi.sock
chmod-socket = 660
chdir = /opt/awx
module = awx.wsgi:application
home = /var/lib/awx/venv/awx
env = AWX_MODE=production
master = true
processes = 4
harakiri = 120
buffer-size = 32768
max-requests = 1000
reload-on-rss = 800
vacuum = true
lazy-apps = true
EOF
```

## supervisord.conf

Programs run as `awx`; supervisord itself runs as root (so it can drop privileges). The `[group:tower-processes]` line lets you restart the whole family with `supervisorctl restart tower-processes:*`.

> **The names are not a style choice.** AWX's own code shells out to supervisor: `awx/main/utils/reload.py` builds `supervisorctl restart tower-processes:<name>` with the group name **hardcoded**, and `run_rsyslog_configurer` restarts the program literally named `awx-rsyslogd`. Rename the group or programs and those calls fail with a `FATAL`-looping rsyslog-configurer (this lab originally used a cute `ace` group — that's exactly how it broke). Two more things the same code path needs on a from-source build: `supervisorctl` findable on the program's `PATH` (ours lives in the venv, not `/usr/bin`) and `SUPERVISOR_CONFIG_PATH` pointing at our non-default config location — both are baked into the `environment=` lines below.

```bash
sudo tee /etc/tower/supervisord.conf >/dev/null <<'EOF'
[unix_http_server]
file=/var/run/tower/supervisor.sock
chmod=0770
chown=awx:awx

[supervisord]
umask=022
minfds=4096
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/tower/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/tower/supervisor.sock

[program:awx-uwsgi]
command=/var/lib/awx/venv/awx/bin/uwsgi /etc/tower/uwsgi.ini
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
stopsignal=INT
stopwaitsecs=15
stopasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-uwsgi.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-daphne]
; TCP for first bring-up (curl-able); Lab 10 moves this to a unix socket
command=/var/lib/awx/venv/awx/bin/daphne -b 127.0.0.1 -p 8051 awx.asgi:channel_layer
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
stopwaitsecs=5
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-daphne.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-dispatcher]
command=/var/lib/awx/venv/awx/bin/awx-manage dispatcherd
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
stopwaitsecs=60
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-dispatcher.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx",SUPERVISOR_CONFIG_PATH="/etc/tower/supervisord.conf",PATH="/var/lib/awx/venv/awx/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"

[program:awx-callback-receiver]
command=/var/lib/awx/venv/awx/bin/awx-manage run_callback_receiver
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-callback-receiver.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-wsrelay]
command=/var/lib/awx/venv/awx/bin/awx-manage run_wsrelay
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-wsrelay.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-ws-heartbeat]
command=/var/lib/awx/venv/awx/bin/awx-manage run_ws_heartbeat
directory=/var/lib/awx
user=awx
autostart=true
autorestart=true
stopwaitsecs=5
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-ws-heartbeat.log
stdout_logfile_maxbytes=10MB
stdout_logfile_backups=10
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[group:tower-processes]
programs=awx-uwsgi,awx-daphne,awx-dispatcher,awx-callback-receiver,awx-wsrelay,awx-ws-heartbeat
priority=5
EOF
```

Details worth knowing (all folded in above): every program runs with `directory=/var/lib/awx` and gets `HOME`/`USER` in its environment; supervisord itself runs `umask=022 minfds=4096`; every log rotates at 10 MB × 10. Program names, log file names, and the `tower-processes` group (with `priority=5`) are dictated by AWX's own code — see the warning above for why. Two additions of our own: `AWX_MODE=production` everywhere (war story below), and `SUPERVISOR_CONFIG_PATH` + a venv-first `PATH` on the dispatcher (it's the process that calls back into supervisorctl at runtime — e.g. reconfiguring rsyslog when you change logging settings in the API).

> **Why `AWX_MODE` is on EVERY program — a war story.** A packaged AWX never needs this, because a release package defaults to production. A from-source build gets pushed the other way by two separate things, and you need *both* fixed. The first is the code-path `MODE`, decided by the `devonly` marker file — Lab 5 already deleted it, so `MODE` is now `production`. The second is `AWX_MODE`: it selects the *settings files*, and a process that starts without `AWX_MODE=production` loads the dev sqlite defaults instead of `/etc/tower` + postgres. Miss it and a process runs half-in, half-out: production code paths reading development config, dying in strange ways. If you *hadn't* deleted `devonly`, the pairing bites hardest in the dispatcher: `MODE=='development'` + production settings makes the scheduled task manager raise `AttributeError: 'Settings' object has no attribute 'AWX_DISABLE_TASK_MANAGERS'` on every tick, and every job you launch hangs in `pending` (see Lab 5's `devonly` fix for the full autopsy). General lesson: an `AttributeError` on a settings name means a mode mismatch — check `devonly` and the process's environment *first*, not the settings file. The Lab 5 wrapper bakes `AWX_MODE` in for manual commands for the same reason.

## The one systemd unit

```bash
sudo tee /etc/systemd/system/automation-controller.service >/dev/null <<'EOF'
[Unit]
Description=AWX automation controller (supervisord process family)
After=network.target postgresql.service redis.service
Wants=postgresql.service redis.service

[Service]
Type=simple
ExecStart=/var/lib/awx/venv/awx/bin/supervisord -n -c /etc/tower/supervisord.conf
ExecStop=/var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf shutdown
Restart=on-failure

[Install]
WantedBy=multi-user.target
EOF
```

## SELinux: label the venv executables

Rocky 9 runs SELinux enforcing, and systemd (`init_t`) may not execute binaries labeled `var_lib_t` — which is everything under `/var/lib/awx`. Skip this and the unit dies with `203/EXEC`. Relabel the venv's `bin/` as `bin_t` — and add the fcontext rule first, so the label survives a filesystem relabel:

```bash
sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/awx/venv/awx/bin(/.*)?'
sudo restorecon -Rv /var/lib/awx/venv/awx/bin
```

## Start it

```bash
sudo systemctl daemon-reload
sudo systemctl enable --now automation-controller
```

## Verify

```bash
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf status
# want: all six programs RUNNING

ls -l /var/run/tower/uwsgi.sock          # want: srw-rw---- awx nginx  (group "nginx" via setgid, not awx)

sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage list_instances'
# want: ace-control now shows capacity > 0 and a real version (it's heartbeating)
```

Kill a child and watch supervisord bring it back:

```bash
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf restart tower-processes:awx-dispatcher
```

## Add rsyslog (the last two programs)

AWX runs on file logging without this, so add it once the core is green. Program names verbatim, again — `run_rsyslog_configurer` restarts `tower-processes:awx-rsyslogd` by that literal name:

```ini
[program:awx-rsyslogd]
command=rsyslogd -n -i /var/run/awx-rsyslog/rsyslog.pid -f /var/lib/awx/rsyslog/rsyslog.conf
user=awx
autostart=true
autorestart=true
startsecs=0
stopsignal=TERM
stopasgroup=true
killasgroup=true
stdout_logfile=/var/log/supervisor/awx-rsyslog.log

[program:awx-rsyslog-configurer]
command=/var/lib/awx/venv/awx/bin/awx-manage run_rsyslog_configurer
directory=/var/lib/awx
user=awx
autorestart=true
startsecs=0
stopasgroup=true
killasgroup=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/awx-rsyslog-configurer.log
environment=AWX_MODE="production",HOME="/var/lib/awx",USER="awx",SUPERVISOR_CONFIG_PATH="/etc/tower/supervisord.conf",PATH="/var/lib/awx/venv/awx/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin"
```

The configurer's `environment=` carries the two from-source extras (`SUPERVISOR_CONFIG_PATH`, venv-first `PATH`) because its whole job is calling `supervisorctl` — without them it dies with `FileNotFoundError: 'supervisorctl'`. We also add `redirect_stderr=true`: without it the traceback from a crash goes nowhere and you stare at an empty log wondering why it's `FATAL`. `startsecs=0` is required — the configurer runs, configures, and exits by design; without it supervisor calls that "exited too quickly" and gives up in `FATAL`.

Prereqs when you do it: `dnf install rsyslog`, `install -d -o awx -g awx /var/lib/awx/rsyslog`, a tmpfiles.d entry for `/var/run/awx-rsyslog` (0750 awx awx), add both programs to the `[group:tower-processes]` list.

Next: [Building the UI](09-awx-ui.md)
