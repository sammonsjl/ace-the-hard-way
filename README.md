# ACE the Hard Way

This tutorial walks you through building an open source automation platform the hard way — **from source, bare metal** — so you understand every process, every config file, and every wire. "Bare metal" means literally that: every service is a real process on the box, and containers appear in exactly one role — as execution-environment sandboxes for jobs.

The goal is precise: **hand-build a complete automation platform from upstream source** — a dedicated service user, a deliberate directory layout (AWX's historical `/etc/tower` paths included, on purpose), a supervisor process family you write yourself, and nginx wiring you can read end to end. Every piece is a real process you can inspect, restart, and break.

It builds that architecture from upstream community projects:

- **Control node** — built by hand on a Linux VM: PostgreSQL, Redis, [AWX](https://github.com/ansible/awx) built from source into a virtualenv, its UI built from source, every process (uwsgi, daphne, dispatcher, callback receiver, wsrelay) running under **supervisord configs you wrote** — the same process topology a real production deployment runs — plus receptor from the release binary, behind nginx. Then the platform gateway on top.
- **Execution plane** — a second VM (its first node) joined over a **receptor mesh you build yourself**: release binary, hand-made TLS certs, work signing. Jobs dispatch across the mesh and run there in execution environments. Later, the same plane concept extends to Kubernetes via container groups — the control plane never knows the difference.

No installer. No operator. No docker-compose. No Kubernetes.

> Inspired by [kubernetes-the-hard-way](https://github.com/kelseyhightower/kubernetes-the-hard-way): there the binaries are the artifacts and you write the units by hand. AWX doesn't ship runnable binaries — so here you build the artifacts from source too, then still write every unit by hand. Where upstream *does* ship a real binary (receptor, envoy, k3s), we use the tarball, KTHW style.
>
> The results are not production-ready. The *understanding* is the product.

## What you end up with

Two VMs, nineteen labs later. Every box below is a process you started by hand, from a config file you wrote:

```mermaid
flowchart TB
    browser(["browser"])

    subgraph GW["ace-gateway · 192.168.56.11"]
        envoy["envoy :443<br/>the single front door · TLS ends here"]
        gwnginx["nginx :8443<br/>gateway API + the console SPA"]
        gwuwsgi["uwsgi 127.0.0.1:8050<br/>REST API + the service registry"]
        gwgrpc["gRPC control plane :50051<br/>authorises every proxied request"]
        redis[("Redis<br/>unix socket locally · :6379 for EDA")]
    end

    subgraph CTL["ace-controller · 192.168.56.12 — hybrid node"]
        ctlnginx["nginx :443"]
        ctlsup["supervisord · tower-processes<br/>awx-uwsgi · awx-daphne · awx-dispatcher<br/>awx-callback-receiver · awx-wsrelay · awx-ws-heartbeat<br/>awx-rsyslogd · awx-rsyslog-configurer"]
        rcontrol["receptor<br/>control socket · work signing · local work type"]
        podmanc["podman — EE containers<br/>project syncs, system jobs AND your jobs"]
    end

    subgraph HUB["ace-hub · 192.168.56.13"]
        hubnginx["nginx :443"]
        hubproc["pulpcore-api · pulpcore-content<br/>pulpcore-worker@1 · @2"]
    end

    subgraph EDA["ace-eda · 192.168.56.14"]
        edanginx["nginx :443"]
        edaproc["eda api · websockets · scheduler · worker"]
    end

    subgraph DB["ace-db · 192.168.56.10"]
        pg[("PostgreSQL :5432<br/>awx · gateway · pulp · eda")]
    end

    browser -->|"80/443"| envoy
    envoy -->|"/"| gwnginx
    envoy -->|"/api/controller/"| ctlnginx
    envoy -->|"/api/galaxy/"| hubnginx
    envoy -->|"/api/eda/"| edanginx
    gwnginx -->|"/api/gateway/"| gwuwsgi
    ctlnginx -->|"uwsgi.sock · daphne.sock"| ctlsup
    hubnginx -->|"pulpcore-api.sock · pulpcore-content.sock"| hubproc
    edanginx -->|"eda-api.sock"| edaproc

    gwuwsgi -.->|"xDS: routes from the registry, every 5s"| envoy
    envoy -.->|"is this request allowed? who is it?"| gwgrpc
    gwuwsgi -.->|"JWT public key — one identity<br/>for all three services"| ctlsup
    gwuwsgi -.-> hubproc
    gwuwsgi -.-> edaproc

    gwuwsgi -.->|"5432"| pg
    ctlsup -.->|"5432"| pg
    hubproc -.->|"5432"| pg
    edaproc -.->|"5432"| pg

    gwuwsgi -.->|"unix socket"| redis
    edaproc -.->|"6379 across the network"| redis

    ctlsup -->|"signed work units, control socket"| rcontrol
    rcontrol -->|"work-command → ansible-runner"| podmanc

    classDef box fill:#f6f8fa,stroke:#57606a,color:#24292f
    classDef front fill:#ddf4ff,stroke:#0969da,color:#0a3069
    classDef store fill:#fff8c5,stroke:#9a6700,color:#4d2d00
    classDef sandbox fill:#fbefff,stroke:#8250df,color:#3b1e63
    class envoy,gwnginx,ctlnginx,hubnginx,edanginx front
    class pg,redis store
    class podmanc sandbox
```

A few things the picture is meant to make obvious. **One front door:** envoy on 443 is the only port a browser touches. **But envoy is only the data plane — the gateway is what assembles the platform.** Envoy knows nothing on its own: every route it serves is a row in the gateway's service registry, fetched over xDS every five seconds; every request it proxies is checked against the gateway's gRPC control plane; and the identity that comes back is a JWT signed by the gateway, which the controller, hub and EDA each validate against a public key they fetch from it at runtime (`ANSIBLE_BASE_JWT_KEY`). That is what "one login for the whole platform" means mechanically — three independently built services trusting one issuer. Rotate the key at the gateway and all three follow. **Every component serves 443 on its own host**, because it has a host to itself; only the gateway uses 8443, and only because envoy shares its machine and owns 443 there. **nginx-to-app hops are unix sockets, not TCP** — nothing for a remote client to reach. **Containers appear once, as the EE sandbox** (purple) — never as a service you build. **Receptor is the parent of podman:** the dispatcher never launches a container itself, it submits a *signed* work unit to receptor, and receptor's work-command spawns `ansible-runner`, which starts the EE. The controller is a **hybrid** node, so project syncs, system jobs and your jobs all take that path on the same machine — a production build of this topology splits execution onto its own VM and changes nothing else. And the one thing every VM shares is the CA in [Lab 3](docs/03-internal-ca.md): five trust stores, one root, and no private key that ever crossed a machine boundary.

## Who this is for

You run (or will run) AWX or a similar automation platform, and you want to know what's actually inside — not just what an install script prints at you. Bare-metal AWX hasn't been officially supported since v18; this is the map nobody publishes anymore.

## What you need

- A laptop with ~16 GB RAM free for VMs
- [Vagrant](https://developer.hashicorp.com/vagrant) with a supported provider — run end-to-end on **KVM/libvirt (Linux, x86_64)** and **VMware Fusion (macOS, Apple Silicon or Intel)**; the default box publishes both architectures. Pick your track in [Lab 1](docs/01-prerequisites.md).
- Patience — that's the "hard way" part

## Labs

**Foundations**

1. [Prerequisites](docs/01-prerequisites.md)
2. [The five VMs](docs/02-vms.md) — the estate, and why each component gets its own machine
3. [The internal CA](docs/03-internal-ca.md) — one root, trusted everywhere, signing every service

**The components, one lab each**

4. [PostgreSQL](docs/04-postgresql.md) — `ace-db`; four roles, four databases, one server
5. [The platform gateway](docs/05-gateway.md) — `ace-gateway`; jewel, Redis, nginx, the console, envoy — then it registers itself and 443 opens
6. [The automation controller](docs/06-controller.md) — `ace-controller`; AWX, receptor as a hybrid node, podman — then it registers, and you run a job from the console
7. [Automation hub](docs/07-hub.md) — `ace-hub`; galaxy_ng on pulpcore
8. [Event-Driven Ansible](docs/08-eda.md) — `ace-eda`; eda-server, and the loop closes

**Appendix labs — break it on purpose**

- [A1: The EPEL uwsgi conflict](docs/a1-epel-uwsgi-conflict.md) — deliberately clobber your uwsgi, diagnose the ABI mismatch, armor the box with `excludepkgs`
- [A2: Backup and restore](docs/a2-backup-restore.md) — what actually holds state, and proving you can get it back

— [Glossary](docs/glossary.md) · [Cleanup](docs/99-cleanup.md)

## A note on containers

Everything you build and operate is bare metal. Podman appears only as the **execution-environment sandbox**, on every node that runs work — jobs on the execution plane, project syncs and system jobs on the controller — because an EE *is* a container image and AWX has had no containerless execution since v18. That is the only place podman appears: no service you build runs in a container.

ACE is an independent assembly of upstream community projects — [AWX](https://github.com/ansible/awx), [ansible-ui](https://github.com/ansible/ansible-ui), [receptor](https://github.com/ansible/receptor), [jewel](https://github.com/ansible/jewel), [galaxy_ng](https://github.com/ansible/galaxy_ng), and [eda-server](https://github.com/ansible/eda-server) — plus [envoy](https://github.com/envoyproxy/envoy) as the gateway's proxy, wired together by hand.

## License

Content is licensed CC BY 4.0 unless noted otherwise.
