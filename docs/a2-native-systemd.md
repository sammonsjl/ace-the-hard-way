# Appendix Lab A2 — The same stack, native systemd

> Optional alternative to Lab 8. Same six processes, no supervisord: every process as a first-class systemd unit.

## What you will have at the end

The controller managed directly by systemd — per-process `systemctl status`, native journald logs, real `After=`/`Requires=` dependencies, systemd restart policies. What the platform would look like if it were designed today.

## Outline (to be written)

- [ ] One unit per process: `awx-uwsgi`, `awx-daphne`, `awx-dispatcher`, `awx-callback-receiver`, `awx-wsrelay` (+ rsyslog config)
- [ ] Shared `EnvironmentFile`, absolute venv paths, `User=awx`
- [ ] Dependency graph between units; a target unit (`automation-controller.target`) to start/stop the family
- [ ] Compare against Lab 8 honestly: where does each approach hide failures? Which is easier at 3am?

Back to the [README](../README.md)
