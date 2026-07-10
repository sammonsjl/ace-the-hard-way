# Lab 14 — Smoke test — run a job on the execution plane

## What you will have at the end

The whole point: a job launched on your hand-built control plane, dispatched over YOUR receptor mesh, executed on the execution plane you built.

## Outline (to be written)

- [ ] Terminal 1: `awx job_templates launch 'Demo Job Template' --monitor`
- [ ] Terminal 2 on ace-exec: `podman ps -w`-style watch, plus `receptorctl work list` on control
- [ ] Success: EE container appears on ace-exec, stdout streams back over the mesh, job goes successful
- [ ] Trace the hops: dispatcher → receptor control socket → TLS mesh → ace-exec work-command → ansible-runner → EE. You built every one.

Next: [The gateway](15-gateway.md)
