# Lab 8 — Running the services

## What you will have at the end

Every AWX process running under **supervisord** — exactly like a real AAP VM deployment — with one systemd unit at the top, and every config written by hand. `list_instances` finally shows real capacity and a version.

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

## Socket directory (survives reboot)

`/var/run` is tmpfs — wiped on reboot. A `tmpfiles.d` entry recreates the socket dir every boot:

```bash
sudo tee /etc/tmpfiles.d/tower.conf >/dev/null <<'EOF'
d /run/tower 0755 awx awx -
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

Programs run as `awx`; supervisord itself runs as root (so it can drop privileges). The `[group:ace]` line lets you restart the whole family with `supervisorctl restart ace:*`.

```bash
sudo tee /etc/tower/supervisord.conf >/dev/null <<'EOF'
[unix_http_server]
file=/var/run/tower/supervisor.sock
chmod=0770

[supervisord]
logfile=/var/log/supervisor/supervisord.log
pidfile=/var/run/tower/supervisord.pid

[rpcinterface:supervisor]
supervisor.rpcinterface_factory = supervisor.rpcinterface:make_main_rpcinterface

[supervisorctl]
serverurl=unix:///var/run/tower/supervisor.sock

[program:uwsgi]
command=/var/lib/awx/venv/awx/bin/uwsgi /etc/tower/uwsgi.ini
user=awx
autostart=true
autorestart=true
stopsignal=INT
redirect_stderr=true
stdout_logfile=/var/log/supervisor/uwsgi.log
environment=AWX_MODE="production"

[program:daphne]
; TCP for first bring-up (curl-able); Lab 10 moves this to the bundle's unix socket
command=/var/lib/awx/venv/awx/bin/daphne -b 127.0.0.1 -p 8051 awx.asgi:channel_layer
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/daphne.log
environment=AWX_MODE="production"

[program:dispatcher]
command=/var/lib/awx/venv/awx/bin/awx-manage dispatcherd
user=awx
autostart=true
autorestart=true
stopwaitsecs=60
redirect_stderr=true
stdout_logfile=/var/log/supervisor/dispatcher.log
environment=AWX_MODE="production"

[program:callback-receiver]
command=/var/lib/awx/venv/awx/bin/awx-manage run_callback_receiver
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/callback-receiver.log
environment=AWX_MODE="production"

[program:wsrelay]
command=/var/lib/awx/venv/awx/bin/awx-manage run_wsrelay
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/wsrelay.log
environment=AWX_MODE="production"

[program:ws-heartbeat]
command=/var/lib/awx/venv/awx/bin/awx-manage run_ws_heartbeat
user=awx
autostart=true
autorestart=true
redirect_stderr=true
stdout_logfile=/var/log/supervisor/ws-heartbeat.log
environment=AWX_MODE="production"

[group:ace]
programs=uwsgi,daphne,dispatcher,callback-receiver,wsrelay,ws-heartbeat
EOF
```

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

Rocky 9 runs SELinux enforcing, and systemd (`init_t`) may not execute binaries labeled `var_lib_t` — which is everything under `/var/lib/awx`. Skip this and the unit dies with `203/EXEC`. Relabel the venv's `bin/` as `bin_t`, the same way the installer sets contexts:

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

ls -l /var/run/tower/uwsgi.sock          # want: the socket exists

sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage list_instances'
# want: ace-control now shows capacity > 0 and a real version (it's heartbeating)
```

Kill a child and watch supervisord bring it back:

```bash
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf restart ace:dispatcher
```

## Add rsyslog (the last two programs)

AWX runs on file logging without this, so add it once the core is green. The bundle runs `awx-rsyslogd` and `awx-manage run_rsyslog_configurer` as two more supervised programs writing to `/var/run/awx-rsyslog/rsyslog.sock`. Left as the next increment.

Next: [Building the UI](09-awx-ui.md)
