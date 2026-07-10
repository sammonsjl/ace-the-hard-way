# Lab 7 — Configuring AWX

## What you will have at the end

Settings, secrets, and database config written by hand.

## Outline (to be written)

- [ ] The settings file layout (what the container entrypoint normally generates — now you write it)
- [ ] `SECRET_KEY` generation and placement (mode 0400, dedicated user)
- [ ] Database connection settings (postgres from Lab 3)
- [ ] Redis/websocket + cache settings (socket from Lab 4)
- [ ] Project dirs, job output dirs, ownership
- [ ] Verify: `awx-manage check` passes

## From the real installer (2.6 RPM bundle) — the /etc/tower layout

- [ ] `/etc/tower/settings.py` — the "DO NOT EDIT" base (STATIC_ROOT, PROJECTS_ROOT, JOBOUTPUT_ROOT under /var/lib/awx)
- [ ] `/etc/tower/SECRET_KEY` — separate 0400 file, read by settings at import
- [ ] `/etc/tower/conf.d/*.py` fragments — one concern per file: `postgres.py`, `channels.py` (includes a generated broadcast-websocket secret), `cluster_host_id.py`, `execution_environments.py`, `container_groups.py`, `callback_receiver_workers.py`
- [ ] Mirror this layout — it's tidy and it matches what any AAP admin already knows

Next: [Database init](08-awx-init.md)
