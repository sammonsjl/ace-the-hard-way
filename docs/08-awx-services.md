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

## Why supervisord, and not eight systemd units

The obvious objection: this is a modern systemd box, so why run a process manager *under* systemd instead of writing one unit per process? Native units would give you per-process `systemctl status`, journald, and real `After=`/`Requires=` — genuinely nicer than what we're about to build.

Two reasons we don't.

**Fidelity.** The RPM install runs supervisord with a single `automation-controller.service` on top, and this tutorial's whole premise is reproducing that end state by hand. Writing units instead would build something *better* and less true.

**AWX won't let you.** This is the part that actually settles it: AWX restarts its own processes by shelling out to supervisord, with both the binary and the group name hardcoded. From `awx/main/utils/reload.py`:

```python
args = ['supervisorctl']
args.extend([command, ':'.join(['tower-processes', service])])
```

`run_rsyslog_configurer` does the same to restart `tower-processes:awx-rsyslogd` by that literal name. Remove supervisord and those calls have nothing to talk to — change a logging setting in the API and the reconfiguration fails, quietly, while everything *looks* healthy. You could stub a fake `supervisorctl` that translates to `systemctl`, which is a fun exercise, but it isn't "native systemd" any more and it isn't what the installer builds.

So: supervisord manages the processes, systemd manages supervisord, and the program and group names are dictated by AWX rather than chosen by us — see the warning below.

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

AWX runs on file logging without this, so add it once the core is green.

### Prereqs

First the daemon itself — Rocky's minimal install doesn't ship it:

```bash
sudo dnf -y install rsyslog
rsyslogd -v | head -1        # record the version
```

Then the config directory the configurer writes into. It lives under the service user's home, like everything else AWX owns:

```bash
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/rsyslog
```

And the runtime directory for the pid file. `/var/run` is a tmpfs, so this needs a tmpfiles.d entry to survive a reboot — the same pattern as `/var/run/tower` in Lab 2:

```bash
sudo tee /etc/tmpfiles.d/awx-rsyslog.conf >/dev/null <<'TMPEOF'
d /var/run/awx-rsyslog 0750 awx awx -
TMPEOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/awx-rsyslog.conf
ls -ld /var/run/awx-rsyslog        # want: awx:awx 0750
```

### The two programs

Program names verbatim, again — `run_rsyslog_configurer` restarts `tower-processes:awx-rsyslogd` by that literal name. Append both blocks to `/etc/tower/supervisord.conf`:

```bash
sudo vim /etc/tower/supervisord.conf
```

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
redirect_stderr=true
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

### Add them to the group

Both programs must join `[group:tower-processes]` — that's the group name AWX's code restarts by. In the same file, extend the `programs=` line to all eight:

```ini
[group:tower-processes]
programs=awx-uwsgi,awx-daphne,awx-dispatcher,awx-callback-receiver,awx-wsrelay,awx-ws-heartbeat,awx-rsyslogd,awx-rsyslog-configurer
priority=5
```

### Load and verify

`reread` picks up the new config, `update` starts only what changed — no need to bounce the running core:

```bash
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf reread
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf update
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf status
# want: all eight programs listed; awx-rsyslogd RUNNING
```

`awx-rsyslog-configurer` is expected to show `EXITED` (it configures and exits by design — that's what `startsecs=0` is for). If `awx-rsyslogd` flaps briefly on first start, that's the chicken-and-egg: it's launched with `-f /var/lib/awx/rsyslog/rsyslog.conf`, which the configurer writes. `autorestart=true` brings it back once the file exists — confirm the file landed:

```bash
sudo ls -l /var/lib/awx/rsyslog/rsyslog.conf
```

**Then check it actually stayed up**, because a permanent flap looks almost identical to a brief one in `status` — the state says `RUNNING` either way, and only the uptime gives it away:

```bash
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf status tower-processes:awx-rsyslogd
sleep 8
sudo /var/lib/awx/venv/awx/bin/supervisorctl -c /etc/tower/supervisord.conf status tower-processes:awx-rsyslogd
# want: the uptime GREW and the pid is unchanged. A fresh pid with uptime 0:00:00
#       both times means it is restarting in a loop.
```

> **War story — the flap you can't see.** If it is looping, the usual cause is the runtime directory: skip the `/etc/tmpfiles.d/awx-rsyslog.conf` step above (or reboot without it, since `/run` is tmpfs) and rsyslogd cannot create its socket or pid file. It exits immediately, supervisor restarts it, forever.
>
> What makes it expensive is that **the log is empty**: rsyslogd writes that error to *stderr*, and without `redirect_stderr=true` supervisor throws it away — which is why the directive is in the program block above. Add it and the reason is right there in `/var/log/supervisor/awx-rsyslog.log`:
>
> ```
> rsyslogd: cannot create '/var/run/awx-rsyslog/rsyslog.sock': No such file or directory
> rsyslogd: imuxsock does not run because we could not acquire any socket
> rsyslogd: run failed with error -3000
> ```
>
> The fix is the tmpfiles.d entry, then `supervisorctl restart tower-processes:awx-rsyslogd`. You can always reproduce the real error by running the command by hand, which is how you find it when stderr is going nowhere:
>
> ```bash
> sudo -u awx timeout 5 rsyslogd -n -i /var/run/awx-rsyslog/rsyslog.pid -f /var/lib/awx/rsyslog/rsyslog.conf
> ```

Next: [Building the UI](09-awx-ui.md)
