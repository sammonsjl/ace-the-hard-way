# Lab 7 — Execution: receptor and podman

> **Not written yet.** Goal and outline below; unchecked boxes are undone.

## What you will have at the end

The controller able to run a job: receptor built from source, work signing you set up yourself, an execution environment you built with `ansible-builder`, and the first playbook running in a container started by a container.

## Where it fits

[Lab 6](06-controller.md) gives you a controller that schedules work and cannot execute any. This is the other half.

On the bare-metal track this lab is mostly about receptor and a signed work unit. Here it is that *plus* the hardest container problem in the tutorial: **podman inside podman, rootless both times**. The receptor container has to start EE containers, which means it needs a podman that works from inside a user namespace that is already inside a user namespace.

This is the one lab that gets genuinely harder in containers, and the one where the containerized track teaches more than the bare-metal one rather than less.

## Outline

- [ ] receptor from source — a Go build, the simplest Containerfile in the tutorial
- [ ] The execution environment, built with `ansible-builder` rather than pulled
- [ ] The decision environment for [Lab 9](09-eda.md), same pattern
- [ ] Work signing: the keypair, and why the controller signs what it hands over
- [ ] receptor's control socket, and the quadlet, on 27199
- [ ] **Nested rootless podman** — how the receptor container gets a usable podman, what the bundle mounts to make it work, and what breaks first when it does not
- [ ] Why receptor is the parent of podman and never the reverse
- [ ] The single-node mesh: no inter-node TLS, no mesh CA, and what adding a second node would restore
- [ ] Verify: a project sync, then a job template, both landing in an EE container

## Open questions

- The bundle mounts the host's podman binary into the receptor container (`~/aap/containers/podman:/usr/bin/podman`). Is that the right shape here, or should the image carry its own?
- Whether `keep-id` composes cleanly across two levels of user namespace, or whether the EE containers need different handling.

Next: [Automation hub](08-hub.md)
