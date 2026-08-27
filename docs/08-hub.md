# Lab 8 — Automation hub

> **Not written yet.** Goal and outline below; unchecked boxes are undone.

## What you will have at the end

galaxy_ng on pulpcore, built from source, registered with the gateway — the private content repository the controller pulls collections and execution environments from.

## Where it fits

By this lab the build pattern from [Lab 5](05-gateway.md) should be routine. Hub is where you find out whether it is: same shape, different application, and one wrinkle of its own — hub is two containers, an application and an nginx that muxes to it.

**There is a working reference**: `ace-images/hub/Containerfile` builds galaxy_ng on a pulp base. Read it; do not paste it.

## Outline

- [ ] The Containerfile — galaxy_ng on `pulp/base`, pinned
- [ ] Why this is built rather than pulled: the published galaxy-ng image is amd64-only and `pulp/pulp-galaxy-ng` is abandoned
- [ ] Forcing `django-ansible-base` to a matching ref so hub's JWT dialect agrees with the gateway's
- [ ] `hub-web` — plain nginx plus a config you write, the one "assembled" image in the tutorial
- [ ] The four pulpcore processes: api, content, and two workers
- [ ] nginx on 8444, and the sockets behind it
- [ ] Registration with the gateway
- [ ] Verify: Automation Content appears in the console, and the controller can pull a collection from it

## Open questions

- The pip pin check against galaxy_ng's `setup.py` is manual in `ace-containerized-installer`. Whether that can be made mechanical here, or has to stay a warning in the lab.

Next: [Event-Driven Ansible](09-eda.md)
