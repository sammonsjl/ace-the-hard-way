# Appendix Lab A3 — Backup and restore

> The real installer ships whole `backup` and `restore` roles — day-two operations are part of the product. Do this after Lab 14.

## What you will have at the end

A backup of your hand-built platform, a deliberately broken platform, and a successful restore.

## Outline (to be written)

- [ ] What actually holds state: postgres (everything), `/etc/tower/SECRET_KEY` (without it the DB's encrypted secrets are unreadable — THE critical file), `/etc/tower/conf.d/`, custom certs, projects dir
- [ ] pg_dump-based backup + the config files, as one archive
- [ ] Break it: drop the database
- [ ] Restore, restart the family, prove a job still runs
- [ ] The lesson: SECRET_KEY + database = the platform; everything else is rebuildable from this tutorial

Back to the [README](../README.md)
