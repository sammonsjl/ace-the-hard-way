# Lab 11 — Running the services

## What you will have at the end

All eight AWX processes running under the **same supervisord the gateway already uses**, their
programs declared in a drop-in of their own, and a systemd unit on top that runs nothing at all.
`list_instances` finally shows real capacity and a version.

```
systemd ─┬─ supervisord.service ── supervisord ─┬─ [group:gateway-processes]   (Lab 6)
         │                                      │
         │                                      └─ [group:tower-processes]
         │                                         ├── awx-uwsgi              (API/WSGI, unix socket)
         │                                         ├── awx-daphne             (websockets/ASGI, unix socket)
         │                                         ├── awx-dispatcher         (task engine)
         │                                         ├── awx-callback-receiver  (job events)
         │                                         ├── awx-wsrelay            (websocket relay)
         │                                         ├── awx-ws-heartbeat       (instance heartbeat)
         │                                         ├── awx-rsyslogd           (log shipping)
         │                                         └── awx-rsyslog-configurer (rewrites rsyslog conf.d)
         │
         └─ automation-controller.service ── /bin/true
```

All commands on **ace-control**.

## The unit that does nothing

That last line is not a mistake, and it's the most interesting thing in this lab.

`automation-controller.service` runs `/bin/true`. It starts nothing, it supervises nothing, and
`systemctl status automation-controller` will tell you it is active while doing absolutely no
work. What it *is* is a handle: nginx, supervisord, redis, and postgresql each get a systemd
drop-in declaring `PartOf=automation-controller.service`, and `PartOf` means "when that unit
stops or restarts, stop or restart me too."

So `systemctl restart automation-controller` bounces the entire controller — web server, process
manager, cache, database — in dependency order, without that unit containing a single line about
how any of them work. It is a lifecycle grouping expressed in systemd's own vocabulary rather
than a wrapper script, and it's why the real thing can say "restart the controller" and mean
something precise.

The alternative — one unit that `ExecStart`s supervisord directly — works, but it conflates
"the process manager" with "the product", and then restarting the product to pick up an nginx
change requires you to remember that nginx isn't in it.

## Why supervisord, and not eight systemd units

The obvious objection: this is a modern systemd box, so why run a process manager *under*
systemd instead of writing one unit per process? Native units would give you per-process
`systemctl status`, journald, and real `After=`/`Requires=`.

**Because AWX won't let you.** AWX restarts its own processes by shelling out to supervisor,
with both the binary and the group name hardcoded. From `awx/main/utils/reload.py`:

```python
args = ['supervisorctl']
args.extend([command, ':'.join(['tower-processes', service])])
```

`run_rsyslog_configurer` does the same to restart `tower-processes:awx-rsyslogd` by that literal
name. Remove supervisord and those calls have nothing to talk to — change a logging setting in
the API and the reconfiguration fails, quietly, while everything *looks* healthy.

Note what that hardcoded call implies: a bare `supervisorctl`, resolved from `PATH`, reading its
**default** config path. [Lab 6](06-gateway.md) put `supervisorctl` in `/usr/local/bin` and the
config at `/etc/supervisord.conf` precisely so this works with no environment variables, no
wrapper, and no `-c` flag. Config in a private directory would need `SUPERVISOR_CONFIG_PATH`
threaded into every program's environment — which works right up until you forget one.

## uwsgi in the venv

uwsgi has to live in the AWX venv, married to our interpreter:

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/pip install uwsgi
```

A pip-built uwsgi is **monolithic** — the venv's Python is compiled into the binary, which is
what lets it import `awx` and load the venv's C extensions. A distro uwsgi is **modular**: the
core has no Python, and its plugin links the *system* interpreter. Point AWX at that one and you
get `ImportError` at best. [Appendix A1](a1-epel-uwsgi-conflict.md) breaks this on purpose and
walks the diagnosis.

supervisord is the opposite case and that's why Lab 6 could install it system-wide: it only ever
*spawns* processes, so it never has to share an interpreter with anything.

## nginx (package only — config is Lab 12)

The socket directory is owned `nginx:nginx`, not `awx:awx` — nginx is the one *reading*
`uwsgi.sock` and `daphne.sock`, and a setgid bit makes every socket awx creates there inherit
the `nginx` group. That needs the `nginx` user to exist, so pull the package in now:

```bash
sudo dnf -y module enable nginx:1.24
sudo dnf -y install nginx
sudo usermod -aG nginx awx     # awx needs group-write on the setgid dir to create sockets
```

## Socket directory

`/var/run` is tmpfs — wiped on reboot. Mode `2775`: the leading `2` is setgid.

```bash
sudo install -d -o nginx -g nginx -m 2775 /var/run/tower
sudo tee /etc/tmpfiles.d/tower.conf >/dev/null <<'EOF'
D /run/tower 2775 nginx nginx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tower.conf
ls -ld /var/run/tower          # want: drwxrwsr-x nginx nginx  (note the 's')
```

## rsyslog groundwork

Do this *before* writing the program list, so rsyslogd starts cleanly the first time instead of
flapping while you work out why.

```bash
sudo dnf -y install rsyslog
rsyslogd -v | head -1        # record the version
```

Three things have to exist: a working directory, a `conf.d` for generated fragments, and a
runtime directory for the socket and pid file.

```bash
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/rsyslog
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/rsyslog/conf.d

sudo install -d -o awx -g awx -m 0750 /var/run/awx-rsyslog
sudo tee /etc/tmpfiles.d/rsyslog.conf >/dev/null <<'EOF'
D /run/awx-rsyslog 0750 awx awx -
EOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/rsyslog.conf
```

Then the seed config. `awx-rsyslogd` is launched with `-f /var/lib/awx/rsyslog/rsyslog.conf`, and
that file has to exist *before* the daemon starts — but its interesting contents are written by
`awx-rsyslog-configurer` at runtime, into `conf.d/`. The seed is the scaffolding that makes the
include work:

```bash
sudo -u awx tee /var/lib/awx/rsyslog/rsyslog.conf >/dev/null <<'EOF'
$WorkDirectory /var/lib/awx/rsyslog
$MaxMessageSize 700000
$IncludeConfig /var/lib/awx/rsyslog/conf.d/*.conf
module(load="imuxsock" SysSock.Use="off")
input(type="imuxsock" Socket="/var/run/awx-rsyslog/rsyslog.sock" unlink="on")
template(name="awx" type="string" string="%msg%")
action(type="omfile" file="/dev/null")
EOF
```

Read that carefully, because every line is doing something:

- **`SysSock.Use="off"`** — do *not* take over `/dev/log`. This rsyslogd is a private log shipper
  for AWX, not the system logger; the OS one keeps running alongside it.
- **`input(... Socket="/var/run/awx-rsyslog/rsyslog.sock" unlink="on")`** — its own socket in its
  own directory, which is why that directory had to exist above.
- **`$IncludeConfig .../conf.d/*.conf`** — the configurer drops external-logging destinations
  here when you set them in the API. The glob matching nothing is fine.
- **`action(type="omfile" file="/dev/null")`** — with no external logger configured, events are
  consumed and discarded. Without a terminal action rsyslog complains about messages with nowhere
  to go.

## uwsgi.ini

```bash
sudo tee /etc/tower/uwsgi.ini >/dev/null <<'EOF'
[uwsgi]
socket = /var/run/tower/uwsgi.sock
chmod-socket = 660
chdir = /opt/awx
module = awx.wsgi:application
home = /var/lib/awx/venv/awx
env = AWX_MODE=production
stats = /var/lib/awx/uwsgi.stats
processes = 4
listen = 128
master = true
no-orphans = true
vacuum = true
buffer-size = 32768
harakiri = 120
harakiri-graceful-timeout = 30
harakiri-graceful-signal = 6
worker-reload-mercy = 30
max-worker-lifetime = 3600
max-requests = 100000
reload-on-rss = 1024
py-call-osafterfork = true
cheaper = 4
cheaper-algo = busyness
cheaper-initial = 4
cheaper-step = 2
EOF
sudo chown root:awx /etc/tower/uwsgi.ini
sudo chmod 0640 /etc/tower/uwsgi.ini
```

`cheaper-algo = busyness` with `cheaper = 4` is adaptive worker scaling — uwsgi runs four workers
and adds more under load rather than pre-forking a fixed pool. `max-worker-lifetime = 3600` and
`reload-on-rss = 1024` recycle workers on age and memory, which is how a long-running Django app
survives a slow leak without anyone noticing.

`listen = 128` is the socket backlog. If you raise it, raise `net.core.somaxconn` to match or the
kernel silently truncates it.

## /etc/supervisord.d/tower.ini

Lab 6 wrote `/etc/supervisord.conf` with `[include] files = supervisord.d/*.ini`. The controller
adds one file there; the gateway's programs are untouched.

> **The names are not a style choice.** `reload.py` builds
> `supervisorctl restart tower-processes:<name>` with the group name **hardcoded**, and
> `run_rsyslog_configurer` restarts the program literally named `awx-rsyslogd`. Rename the group
> or any program and those calls fail — quietly, with a `FATAL`-looping configurer, while
> everything else looks fine. This lab originally used a tidier `ace` group name; that is exactly
> how it broke.

```bash
sudo tee /etc/supervisord.d/tower.ini >/dev/null <<'EOF'
[program:awx-uwsgi]
command = /var/lib/awx/venv/awx/bin/uwsgi /etc/tower/uwsgi.ini
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopsignal = INT
stopwaitsecs = 15
stopasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-uwsgi.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-daphne]
command = /var/lib/awx/venv/awx/bin/daphne -u /var/run/tower/daphne.sock awx.asgi:channel_layer
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 5
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-daphne.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-dispatcher]
command = /var/lib/awx/venv/awx/bin/awx-manage dispatcherd
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 60
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-dispatcher.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-callback-receiver]
command = /var/lib/awx/venv/awx/bin/awx-manage run_callback_receiver
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-callback-receiver.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-wsrelay]
command = /var/lib/awx/venv/awx/bin/awx-manage run_wsrelay
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-wsrelay.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-ws-heartbeat]
command = /var/lib/awx/venv/awx/bin/awx-manage run_ws_heartbeat
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
stopwaitsecs = 5
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-ws-heartbeat.log
stdout_logfile_maxbytes = 10MB
stdout_logfile_backups = 10
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[program:awx-rsyslogd]
command = rsyslogd -n -i /var/run/awx-rsyslog/rsyslog.pid -f /var/lib/awx/rsyslog/rsyslog.conf
user = awx
autostart = true
autorestart = true
startsecs = 0
stopsignal = TERM
stopwaitsecs = 5
stopasgroup = true
killasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-rsyslog.log
stdout_logfile_maxbytes = 0

[program:awx-rsyslog-configurer]
command = /var/lib/awx/venv/awx/bin/awx-manage run_rsyslog_configurer
directory = /var/lib/awx
user = awx
autostart = true
autorestart = true
startsecs = 0
stopasgroup = true
killasgroup = true
redirect_stderr = true
stdout_logfile = /var/log/supervisor/awx-rsyslog-configurer.log
stdout_logfile_maxbytes = 0
environment = AWX_MODE="production",HOME="/var/lib/awx",USER="awx"

[group:tower-processes]
programs = awx-dispatcher,awx-callback-receiver,awx-uwsgi,awx-daphne,awx-wsrelay,awx-rsyslogd,awx-rsyslog-configurer,awx-ws-heartbeat
priority = 5
EOF
```

Things worth knowing, all folded in above:

- **`AWX_MODE=production` on every program that runs Python.** War story below — this one costs
  people hours.
- **`startsecs = 0` on both rsyslog programs.** The configurer runs, configures, and exits by
  design; without this, supervisor calls that "exited too quickly" and parks it in `FATAL`. On
  `awx-rsyslogd` it prevents the same verdict when the configurer restarts it in quick succession.
- **`stdout_logfile_maxbytes = 0` on the rsyslog pair** disables rotation for those two — they're
  low-volume and you want the whole history when something is looping.
- **`redirect_stderr = true` everywhere.** Skip it on `awx-rsyslogd` in particular and its
  failures are invisible: rsyslogd reports startup errors on stderr, supervisor discards them,
  and you get a `RUNNING` status over an empty log while the process restarts forever.
- **`priority = 5`** on the group, matching the gateway's, so both families start together.

> **Why `AWX_MODE` is on every program — a war story.** A packaged AWX never needs this, because
> a release package defaults to production. A from-source build gets pushed the other way by two
> separate things, and you need *both* fixed. The first is the code-path `MODE`, decided by the
> `devonly` marker file — [Lab 8](08-awx-source.md) already deleted it. The second is `AWX_MODE`:
> it selects the *settings files*, and a process that starts without it loads the dev sqlite
> defaults instead of `/etc/tower` + postgres. Miss it and a process runs half in, half out —
> production code paths reading development config, dying in strange ways. The pairing bites
> hardest in the dispatcher: `MODE=='development'` plus production settings makes the scheduled
> task manager raise `AttributeError: 'Settings' object has no attribute
> 'AWX_DISABLE_TASK_MANAGERS'` on every tick, and every job you launch hangs in `pending`.
> **General lesson: an `AttributeError` on a settings name means a mode mismatch** — check
> `devonly` and the process environment first, not the settings file.

## The marker unit and its drop-ins

```bash
sudo tee /etc/systemd/system/automation-controller.service >/dev/null <<'EOF'
[Unit]
Description=Automation Controller service
After=network.target redis.service postgresql.service nginx.service supervisord.service receptor.service
Wants=redis.service postgresql.service nginx.service supervisord.service receptor.service

[Service]
Type=oneshot
RemainAfterExit=true
ExecStart=/bin/true

[Install]
WantedBy=multi-user.target
EOF
```

`Type=oneshot` with `RemainAfterExit=true` is what lets a unit that exits immediately still count
as active — which is the whole trick. `receptor.service` is listed now and arrives in
[Lab 13](13-receptor.md); systemd is fine with `Wants=` on a unit that doesn't exist yet.

Now the drop-ins that make the grouping real:

```bash
for svc in nginx supervisord redis postgresql; do
  sudo install -d -m 0755 "/etc/systemd/system/$svc.service.d"
  sudo tee "/etc/systemd/system/$svc.service.d/override.conf" >/dev/null <<'EOF'
[Unit]
PartOf=automation-controller.service
EOF
done

sudo systemctl daemon-reload
sudo systemctl enable automation-controller
```

## SELinux: label the venv executables

Rocky 9 runs SELinux enforcing, and systemd (`init_t`) may not execute binaries labeled
`var_lib_t` — which is everything under `/var/lib/awx`. Skip this and you get `203/EXEC`. Add the
fcontext rule first so the label survives a filesystem relabel:

```bash
sudo dnf -y install policycoreutils-python-utils
sudo semanage fcontext -a -t bin_t '/var/lib/awx/venv/awx/bin(/.*)?'
sudo restorecon -Rv /var/lib/awx/venv/awx/bin
```

## Start it

`reread` picks up the new drop-in, `update` starts only what changed — the gateway's programs
keep running untouched:

```bash
sudo supervisorctl reread
sudo supervisorctl update
sudo supervisorctl status
```

## Verify

```bash
sudo supervisorctl status
# want: all eight tower-processes:* RUNNING, plus the gateway's two still RUNNING

ls -l /var/run/tower/uwsgi.sock /var/run/tower/daphne.sock
# want: srw-rw---- awx nginx   (group "nginx" via setgid, not awx)

sudo -u awx awx-manage list_instances
# want: ace-control now shows capacity > 0 and a real version (it's heartbeating)
```

Confirm the marker unit really does group things. `PartOf` propagates stop and restart, so:

```bash
systemctl is-active nginx supervisord           # want: active active
sudo systemctl stop automation-controller
systemctl is-active nginx supervisord           # want: inactive inactive — that's PartOf working
sudo systemctl start automation-controller
systemctl is-active nginx supervisord           # want: active active
```

> `PartOf` is deliberately one-directional: stopping nginx does **not** stop the controller. That
> asymmetry is the point — you can bounce one component without tearing down the platform, but
> tearing down the platform takes everything with it.
>
> **On this box it takes the gateway with it, and that is a single-node artifact.** nginx and
> supervisord serve the gateway too, so `systemctl restart automation-controller` bounces the
> platform's front door as a side effect. A real deployment puts the controller and the gateway on
> different hosts, where the same drop-ins only ever touch the controller's own nginx and its own
> supervisord. Worth knowing before you restart the controller expecting the console to stay up —
> it will come back, but not instantly.

Then kill a child and watch supervisord bring it back:

```bash
sudo supervisorctl restart tower-processes:awx-dispatcher
```

And confirm the rsyslog pair settled, because a permanent flap looks almost identical to a brief
one in `status` — the state says `RUNNING` either way and only the uptime gives it away:

```bash
sudo supervisorctl status tower-processes:awx-rsyslogd
sleep 8
sudo supervisorctl status tower-processes:awx-rsyslogd
# want: the uptime GREW and the pid is unchanged. A fresh pid with uptime 0:00:00
#       both times means it is restarting in a loop.
```

`awx-rsyslog-configurer` showing `EXITED` is expected — that's what `startsecs = 0` is for.

> **War story — the flap you can't see.** If `awx-rsyslogd` is looping, the cause is almost always
> the runtime directory: skip the tmpfiles.d entry above (or reboot without it, since `/run` is
> tmpfs) and rsyslogd cannot create its socket or pid file. It exits immediately, supervisor
> restarts it, forever.
>
> What makes it expensive is that **the log is empty** unless `redirect_stderr = true` is set —
> rsyslogd writes these to stderr and supervisor throws them away:
>
> ```
> rsyslogd: cannot create '/var/run/awx-rsyslog/rsyslog.sock': No such file or directory
> rsyslogd: imuxsock does not run because we could not acquire any socket
> rsyslogd: run failed with error -3000
> ```
>
> You can always reproduce the real error by running the command by hand, which is how you find
> it when stderr is going nowhere:
>
> ```bash
> sudo -u awx timeout 5 rsyslogd -n -i /var/run/awx-rsyslog/rsyslog.pid -f /var/lib/awx/rsyslog/rsyslog.conf
> ```

Next: [nginx front door](12-nginx.md)
