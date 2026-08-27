# Lab 6 — The automation controller

> **Not written yet, and blocked.** See below.

## What you will have at the end

AWX built from source into an image you wrote, running eight processes under a supervisord config you wrote, registered with the gateway and browsable in the console — and unable to run a single job until [Lab 7](07-execution.md).

## Where it fits

This is the lab the whole track exists for.

Every containerized build of this platform you can actually obtain is a black box. The vendor's image is private. `quay.io/ansible/awx` is frozen at 24.6.1 — July 2024 — which predates the gateway and django-ansible-base resource-server integration this platform depends on. `ghcr.io/ansible/awx:devel` is a nightly nobody documents. If this lab pulls any of them, the tutorial is lying about the interesting part.

## Blocked on: there is no AWX-from-source image, anywhere

Not in `ace-images` (its README lists building one as still to do). Not in `ace-containerized-installer` (it pulls `ghcr.io/ansible/awx:devel`). Not upstream in any usable form.

Building it is the single largest piece of work on this branch:

- [ ] The AWX UI, built with node, then copied into a runtime image with no node in it
- [ ] The venv, and the C extensions that have to compile against the right Python
- [ ] `receptor` and `ansible-runner` present in the image
- [ ] Both supervisord configs — `supervisord_web.conf` and `supervisord_task.conf` — hand-written
- [ ] The `/etc/tower` layout the application still expects
- [ ] An entrypoint that does not call `awx-manage provision_instance` the way the Kubernetes path does

Recommended first step, and the reason it is worth doing before writing a word of this lab: **pull and dissect the real vendor image** the way `(N) Gateway Image Internals` did for the gateway — entrypoint, supervisord layout, uid, venv path, environment. Observe the end state; copy nothing.

## Outline

- [ ] The Containerfile, once it exists
- [ ] A container is not one process: supervisord runs *inside* the image, because that is what the real containerized build does
- [ ] Web and task as separate containers off one image, as the bundle splits them
- [ ] nginx on 8443, uwsgi on 8050, daphne on 8051
- [ ] `settings.py` and the `conf.d/` fragments, mounted
- [ ] The `SECRET_KEY` as a podman secret
- [ ] Registration with the gateway; the JWT public key fetched at runtime
- [ ] Verify: the console shows Automation Execution, and every job you launch sits in `pending` forever

Next: [Execution: receptor and podman](07-execution.md)
