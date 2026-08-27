# Lab 9 — Event-Driven Ansible

> **Not written yet.** Goal and outline below; unchecked boxes are undone.

## What you will have at the end

eda-server running, registered with the gateway, and the loop closed: an event fires a rulebook, and the rulebook launches a job template on the controller you built in [Lab 6](06-controller.md).

## Where it fits

Last component, and the one that proves the platform is a platform rather than four applications sharing a login. Everything before this was a service registering itself; this is one service *using* another through the gateway's identity.

## Outline

- [ ] The eda-server Containerfile, from source
- [ ] The eda-ui Containerfile — a node build, same shape as the console in [Lab 5](05-gateway.md)
- [ ] The decision environment from [Lab 7](07-execution.md), which is where rulebooks actually run
- [ ] The four processes: gunicorn on 8000, daphne on 8001, scheduler, worker
- [ ] nginx on 8445
- [ ] Redis: EDA is the one component that talks to Redis over the network port rather than the socket
- [ ] Registration with the gateway
- [ ] Verify: a rulebook fires a job template, and the job appears in the controller's job list

Next: [Cleanup](99-cleanup.md) — or [Appendix A2](a2-backup-restore.md) first
