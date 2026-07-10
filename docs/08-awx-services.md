# Lab 8 — Running the services

## What you will have at the end

Every AWX process running under supervisord — exactly like a real AAP VM deployment — with one systemd unit at the top, and every config written by hand.

## The architecture (write this up)

On an RPM-based AAP controller, systemd starts ONE service; that service is **supervisord**, which manages the whole process family. In the real product those supervisor configs arrive pre-baked from the RPM. Here, you write them:

```
systemd ── automation-controller.service ── supervisord ──┬── uwsgi              (API, WSGI)
                                                   ├── daphne             (websockets, ASGI)
                                                   ├── dispatcher         (task engine)
                                                   ├── callback-receiver  (job events)
                                                   ├── wsrelay            (websocket relay)
                                                   └── rsyslog            (external logging)
```

## Outline (to be written)

- [ ] `pip install supervisor uwsgi` INSIDE the venv (both married to our interpreter — see [Appendix A1](a1-epel-uwsgi-conflict.md) for why EPEL's builds must never touch this box)
- [ ] `supervisord.conf` skeleton by hand: main section, unix socket for supervisorctl, include dir
- [ ] One `[program:]` section per process — absolute venv paths, `user=awx`, env vars, autorestart, stopwaitsecs tuned per process (the dispatcher needs grace)
- [ ] `[group:]` section so the family restarts as one (`supervisorctl restart ace:*`)
- [ ] ONE hand-written systemd unit: `automation-controller.service` → runs supervisord in the foreground
- [ ] Operating it: `supervisorctl status`, tail a program's logs, restart one process vs the group
- [ ] Verify: all programs RUNNING, API answers on the uwsgi socket, kill a child and watch supervisord resurrect it

## What supervisord costs you (write this up honestly)

`systemctl status ace-controller` stays green even when a child is flapping — the truth lives one layer down in `supervisorctl` and supervisor's logs, not journald. That's the trade for production parity. [Appendix A2](a2-native-systemd.md) builds the same stack as native systemd units instead, so you can compare both worlds.

## From the real installer (2.6 RPM bundle) — corrections to this outline

The real supervisor config (`tower.conf`) runs **eight** programs, not six:

- [ ] Add `awx-ws-heartbeat` (`awx-manage run_ws_heartbeat`)
- [ ] Add `awx-rsyslogd` + `awx-rsyslog-configurer` (rsyslog runs UNDER supervisord, not as a system service)
- [ ] uwsgi.ini specifics worth copying as behavior: unix socket `/var/run/tower/uwsgi.sock` (chmod 660), `module = awx.wsgi:application`, harakiri timeouts, `buffer-size = 32768`, `max-requests`, `reload-on-rss`, cheaper/busyness worker scaling
- [ ] Per-program logs in `/var/log/supervisor/` with maxbytes+backups, PLUS `/etc/logrotate.d/supervisor` override and an hourly logrotate cron
- [ ] Socket dirs under `/var/run/tower` need a **tmpfiles.d** entry (they vanish on reboot — the installer even ships a `systemd-tmpfiles --create` fix for exactly this)
- [ ] systemd topology: the service is enabled as `automation-controller.service`, and dependent SYSTEM services (postgres, redis, nginx) get `PartOf=` overrides tied to a target — restart the target, the family restarts. Worth reproducing as `automation-controller.target`

Next: [Building the UI](09-awx-ui.md)
