# Lab 6 — Building the UI

## What you will have at the end

The AWX web UI built from source and collected as static files.

## Outline (to be written)

- [ ] `dnf module install nodejs:20` (or nodesource; pin it)
- [ ] Clone `ansible/ansible-ui` at the matching tag — **main branch** (the standalone AWX UI; `devel` is the platform UI for the gateway)
- [ ] `npm ci && npm run build:awx` (RAM hungry — bump the VM if the build dies)
- [ ] Place build output where AWX expects it; `awx-manage collectstatic`
- [ ] Verify: static files exist under the collectstatic target

Next: [Configuring AWX](07-awx-config.md)
