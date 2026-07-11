# ACE the Hard Way

This tutorial walks you through building an open source automation platform the hard way — **from source, bare metal** — so you understand every process, every config file, and every wire. "Bare metal" means exactly what the RPM installer builds: every service a real process on the box, with containers appearing only where the installer puts them (as execution-environment sandboxes for jobs).

The goal is precise: **hand-build, from upstream source, the same end state that Red Hat's RPM installer produces** — same service user, same directory layout (`/etc/tower` legacy paths included, on purpose), same supervisor process family, same nginx wiring. If you administer a real AAP VM install, everything in this lab is where your production instincts expect it.

It builds that architecture from upstream community projects:

- **Control node** — built by hand on a Linux VM: PostgreSQL, Redis, [AWX](https://github.com/ansible/awx) built from source into a virtualenv, its UI built from source, every process (uwsgi, daphne, dispatcher, callback receiver, wsrelay) running under **supervisord configs you wrote** — the same topology as a real AAP VM deployment — plus receptor from the release binary, behind nginx. Then the platform gateway on top.
- **Execution plane** — a second VM (its first node) joined over a **receptor mesh you build yourself**: release binary, hand-made TLS certs, work signing. Jobs dispatch across the mesh and run there in execution environments. Later, the same plane concept extends to Kubernetes via container groups — the control plane never knows the difference.

No installer. No operator. No docker-compose. No Kubernetes.

> Inspired by [kubernetes-the-hard-way](https://github.com/kelseyhightower/kubernetes-the-hard-way): there the binaries are the artifacts and you write the units by hand. AWX doesn't ship runnable binaries — so here you build the artifacts from source too, then still write every unit by hand. Where upstream *does* ship a real binary (receptor, envoy, k3s), we use the tarball, KTHW style.
>
> The results are not production-ready. The *understanding* is the product.

## Who this is for

You run (or will run) Ansible Automation Platform, AWX, or similar, and you want to know what's actually inside — not just what the installer prints. Bare-metal AWX hasn't been officially supported since v18; this is the map nobody publishes anymore.

## What you need

- A laptop with ~16 GB RAM free for VMs
- [Vagrant](https://developer.hashicorp.com/vagrant) with an ARM- or x86-capable provider (this tutorial uses VMware Fusion; the boxes support both architectures)
- Patience — that's the "hard way" part

## Labs

**Foundations**

1. [Prerequisites](docs/01-prerequisites.md)
2. [Provisioning the VMs](docs/02-vms.md)
3. [PostgreSQL](docs/03-postgresql.md)
4. [Redis](docs/04-redis.md)

**AWX from source**

5. [AWX from source](docs/05-awx-source.md)
6. [Configuring AWX](docs/06-awx-config.md)
7. [Database init](docs/07-awx-init.md)
8. [Running the services](docs/08-awx-services.md)
9. [Building the UI](docs/09-awx-ui.md)
10. [nginx front door](docs/10-nginx.md)
11. [Receptor](docs/11-receptor.md)

**Jobs on the mesh**

12. [The execution plane](docs/12-execution-plane.md)
13. [Instance registration](docs/13-instance-registration.md)
14. [Smoke test: run a job on the execution plane](docs/14-smoke-test.md)

**The platform layer**

15. [The gateway](docs/15-gateway.md)
16. [Service registration](docs/16-service-registration.md)

**Appendix labs — break it on purpose**

- [A1: The EPEL uwsgi conflict](docs/a1-epel-uwsgi-conflict.md) — deliberately clobber your uwsgi, diagnose the ABI mismatch, armor the box with `excludepkgs`
- [A2: The same stack, native systemd](docs/a2-native-systemd.md) — rebuild Lab 8 without supervisord and compare both worlds
- [A3: Backup and restore](docs/a3-backup-restore.md) — what actually holds state, and proving you can get it back

— [Glossary](docs/glossary.md) · [Cleanup](docs/99-cleanup.md)

## Scope (v1)

Gateway + controller: single login, jobs running on a hand-built execution plane. Labs 1–14 are a complete working controller on their own; 15–16 add the platform layer.

**Future labs (v2):** scaling the mesh — a hop node relaying to an isolated second execution node (this is AAP's real topology lesson; nothing in this architecture needs quorum, so unlike Kubernetes there's no mandatory scale-out). Also EDA, content hub, and container groups (jobs on Kubernetes). Control-plane HA (multiple AWX nodes + shared postgres behind a load balancer) is deliberately out of laptop scope — that's a "Beyond the lab" topic for real hardware.

## A note on containers

Everything you build and operate is bare metal. Podman appears only as the **execution-environment sandbox**, on every node that runs work — jobs on the execution plane, project syncs and system jobs on the controller — because an EE *is* a container image and AWX has had no containerless execution since v18. That's precisely where the RPM installer puts podman, and nowhere else: no service you build runs in a container.

## Trademark note

This project is not affiliated with or endorsed by Red Hat. "Ansible Automation Platform" and "AAP" are Red Hat trademarks; this tutorial assembles independent upstream community projects (AWX, Receptor, etc.) into a similar architecture, referred to here as **ACE**.

## License

Content is licensed CC BY 4.0 unless noted otherwise.
