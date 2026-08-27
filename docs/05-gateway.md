# Lab 5 — The platform gateway

> **Not written yet.** Goal and outline below; unchecked boxes are undone.

## What you will have at the end

Your first image built from upstream source, envoy in front of it, and a front door on `https://ace-gateway:9443` that opens because the gateway registered itself — not because you pointed a proxy at something.

## Where it fits

This is the **build** pattern lab. Everything before it configured images other people made; from here on you write the Containerfile.

The gateway is the right place to learn it because it is the hardest interesting case: two upstream repos (the API and the console UI) built in separate stages and assembled into one runtime image, a Python venv, nginx, supervisor, uwsgi, and a static build that has to be compiled by node before it can be copied into a container that has no node in it.

**There is a working reference for this**: `ace-images/gateway/Containerfile` builds exactly this image in four stages. Read it, but do not paste it — the lab exists to build it a line at a time.

## Outline

- [ ] The build pattern: base image, pinning upstream refs as `ARG`s, multi-stage, what goes in the image vs what gets mounted
- [ ] Stage 1 — clone [jewel](https://github.com/ansible/jewel) at a pinned ref
- [ ] Stage 2 — clone [ansible-ui](https://github.com/ansible/ansible-ui), `npm ci`, build `platform/` with vite. **This is the 8 GB stage** ([Lab 1](01-prerequisites.md) warns about it)
- [ ] Stage 3 — the venv: CentOS Stream 9, `python3.12 -m venv /opt/aap_gateway/venv`, `requirements.txt` + `requirements_git.txt`
- [ ] Stage 4 — the runtime: nginx 1.24, supervisor, uwsgi, `dumb-init` as PID 1, `collectstatic` baked at build time
- [ ] Why the console is built here rather than pulled: the published platform-UI image is private
- [ ] The gateway certificate from [Lab 3](03-internal-ca.md), mounted not baked
- [ ] The quadlet: nginx on 8446, uwsgi on 8052, gRPC control plane on 50051
- [ ] envoy — release binary in a slim image, **not** built from source, and the lab says why
- [ ] envoy on **9443**, not 443 and not 8443 — see the README's port table
- [ ] xDS: envoy's routes arrive from the gateway's registry every five seconds
- [ ] Registration, and the first login

## Open questions

- Whether the EPEL/uwsgi ABI conflict from [Appendix A1](a1-epel-uwsgi-conflict.md) recurs inside a build stage. The reference Containerfile installs `epel-release`; a build stage has no prior system uwsgi to clash with, but that needs proving rather than assuming.
- Whether `collectstatic` at build time is worth keeping when the console can be rebuilt independently.

Next: [The automation controller](06-controller.md)
