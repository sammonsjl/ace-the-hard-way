# Lab 8 — Database init

## What you will have at the end

A migrated database, an admin user, and a registered instance.

## Outline (to be written)

- [ ] `awx-manage migrate`
- [ ] `awx-manage createsuperuser`
- [ ] `awx-manage provision_instance --hostname=$(hostname)` + `register_queue` (this mirrors the real installer's init chain)
- [ ] `awx-manage create_preload_data` (demo project/inventory/template)
- [ ] Verify: tables exist, instance registered (`awx-manage list_instances`)

Next: [Running the services](09-awx-services.md)
