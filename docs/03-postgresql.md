# Lab 3 — PostgreSQL

## What you will have at the end

PostgreSQL installed from the Rocky repos, with a database and user ready for AWX.

## Outline (to be written)

- [ ] `dnf install postgresql-server` (Rocky 9 module; pick + pin the version)
- [ ] `postgresql-setup --initdb`, enable + start the systemd service
- [ ] `pg_hba.conf`: local + scram-sha-256 auth
- [ ] Create the `awx` database and user
- [ ] Verify: `psql -U awx -h localhost` connects; service survives reboot

> Bare metal note: no containers anywhere in this tutorial. Every service is a real systemd unit you can `systemctl status`.

## From the real installer (2.6 RPM bundle)

- [ ] Tuning the installer applies: `max_connections`, `shared_buffers`, `work_mem`, `maintenance_work_mem` (sized from RAM), `listen_addresses = '*'`
- [ ] Our single-node build can stay on localhost — but document the remote-DB variant since that's the production norm

Next: [Redis](04-redis.md)
