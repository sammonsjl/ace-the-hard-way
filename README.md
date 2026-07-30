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

    subgraph CONTROL["ace-control · 192.168.56.10 — control plane"]
        envoy["envoy :443<br/>the single front door · TLS ends here"]

        subgraph GATEWAY["Platform gateway (jewel) — the integrator"]
            gwgrpc["gRPC control plane :50051<br/>authenticates every proxied request"]
            gwuwsgi["uwsgi :8080<br/>REST API + the service registry"]
            gwnginx["nginx :8446<br/>serves the platform UI SPA"]
        end

        subgraph HUB["Automation hub"]
            hubnginx["nginx :8444"]
            hubproc["pulpcore-api · pulpcore-content<br/>pulpcore-worker@1 · @2"]
        end

        subgraph EDA["Event-Driven Ansible"]
            edanginx["nginx :8445"]
            edaproc["eda api · websockets · scheduler · worker"]
        end

        subgraph CONTROLLER["Automation controller"]
            ctlnginx["nginx :8043"]
            ctlsup["automation-controller.service → supervisord<br/>awx-uwsgi · awx-daphne · awx-dispatcher<br/>awx-callback-receiver · awx-wsrelay · awx-ws-heartbeat<br/>awx-rsyslogd · awx-rsyslog-configurer"]
            rcontrol["receptor · control node<br/>control socket + local work type"]
            podmanc["podman — EE sandbox<br/>project syncs · system jobs"]
        end

        pg[("PostgreSQL :5432<br/>awx · gateway · pulp · eda")]
        redis[("Redis<br/>unix socket, plus loopback :6379 for EDA")]
    end

    subgraph MESH["Automation mesh — ace-exec · 192.168.56.20"]
        rexec["receptor :27199 · tcp-listener"]
        podmane["podman — EE containers<br/>where your jobs actually run"]
    end

    browser -->|"80/443"| envoy
    envoy -->|"/"| gwnginx
    envoy -->|"/api/galaxy/"| hubnginx
    envoy -->|"/api/eda/"| edanginx
    envoy -->|"/api/controller/"| ctlnginx
    gwnginx -->|"/api/gateway/"| gwuwsgi
    hubnginx -->|"pulpcore-api.sock · pulpcore-content.sock"| hubproc
    edanginx -->|"eda-api.sock"| edaproc
    ctlnginx -->|"uwsgi.sock · daphne.sock"| ctlsup

    gwuwsgi -.->|"xDS: routes from the registry, every 5s"| envoy
    envoy -.->|"is this request allowed? who is it?"| gwgrpc
    gwuwsgi -.->|"JWT public key — one identity<br/>for all three services"| ctlsup
    gwuwsgi -.-> hubproc
    gwuwsgi -.-> edaproc

    gwuwsgi -.->|"5432"| pg
    hubproc -.->|"5432"| pg
    edaproc -.->|"5432"| pg
    ctlsup -.->|"5432"| pg

    gwuwsgi -.->|"6379"| redis
    hubproc -.->|"6379 · db 2"| redis
    edaproc -.->|"6379"| redis
    ctlsup -.->|"6379"| redis

    ctlsup -->|"work units, control socket"| rcontrol
    rcontrol -->|"local work-command → ansible-runner"| podmanc
    rcontrol ==>|"27199 · mutual TLS, your own CA<br/>+ work signing"| rexec
    rexec -->|"work-command → ansible-runner"| podmane

    subgraph LEGEND["reading the links"]
        direction LR
        i1(( )) --->|"80/443 http(s) ingress"| i2(( ))
        g1(( )) -.->|"gateway control plane — xDS, gRPC auth, JWT"| g2(( ))
        p1(( )) -.->|"5432 PostgreSQL"| p2(( ))
        r1(( )) -.->|"6379 Redis — job control + caching"| r2(( ))
        m1(( )) ===>|"27199 receptor — work/job execution"| m2(( ))
    end

    linkStyle 0,1,2,3,4,5,6,7,8 stroke:#24292f,stroke-width:1.5px
    linkStyle 9,10,11,12,13 stroke:#bf8700,stroke-width:1.5px
    linkStyle 14,15,16,17 stroke:#0969da,stroke-width:1.5px
    linkStyle 18,19,20,21 stroke:#1a7f37,stroke-width:1.5px
    linkStyle 22,23,24,25 stroke:#cf222e,stroke-width:1.5px
    linkStyle 26 stroke:#24292f,stroke-width:1.5px
    linkStyle 27 stroke:#bf8700,stroke-width:1.5px
    linkStyle 28 stroke:#0969da,stroke-width:1.5px
    linkStyle 29 stroke:#1a7f37,stroke-width:1.5px
    linkStyle 30 stroke:#cf222e,stroke-width:1.5px

    classDef door fill:#1f6feb,stroke:#0b3d8f,color:#ffffff
    classDef ee fill:#8250df,stroke:#4c2889,color:#ffffff
    classDef store fill:#57606a,stroke:#32383f,color:#ffffff
    classDef dot fill:none,stroke:none
    class envoy door
    class podmanc,podmane ee
    class pg,redis store
    class i1,i2,g1,g2,p1,p2,r1,r2,m1,m2 dot
```

A few things the picture is meant to make obvious. **One front door:** envoy on 443 is the only port a browser touches; the four services behind it sit on internal ports (8043/8444/8445/8446). **But envoy is only the data plane — the gateway is what actually assembles the platform.** Envoy knows nothing on its own: every route it serves is a row in the gateway's service registry, fetched over xDS every five seconds; every request it proxies is checked against the gateway's gRPC control plane; and the identity that comes back is a JWT signed by the gateway, which the controller, hub, and EDA each validate against a public key they fetch from it at runtime (`ANSIBLE_BASE_JWT_KEY`). That is what "one login for the whole platform" means mechanically — three independently built services trusting one issuer. Rotate the key at the gateway and all three follow. **The ports are a single-box tax:** the real design gives the controller, hub, and EDA each their own host on 443 — here they share one VM, so they move aside ([Lab 19](docs/19-platform-ui.md) does that pivot). **nginx-to-app hops are unix sockets, not TCP** — nothing for a remote client to reach. **Containers appear twice, both times as EE sandboxes** (purple) — never as a service. **Receptor is the parent of podman on both nodes:** the dispatcher never launches a container itself, it submits a signed work unit to receptor, and receptor's work-command spawns `ansible-runner`, which starts the EE. Control-plane work (project syncs, system jobs) takes that path locally through `ace-control`'s own receptor; job work takes the identical path across the mesh on `ace-exec`. And the two VMs are joined by exactly one thing: that mesh, with a CA, certs, and work-signing keys you generated yourself.

## Who this is for

You run (or will run) AWX or a similar automation platform, and you want to know what's actually inside — not just what an install script prints at you. Bare-metal AWX hasn't been officially supported since v18; this is the map nobody publishes anymore.

## What you need

- A laptop with ~16 GB RAM free for VMs
- [Vagrant](https://developer.hashicorp.com/vagrant) with a supported provider — run end-to-end on **KVM/libvirt (Linux, x86_64)** and **VMware Fusion (macOS, Apple Silicon or Intel)**; the default box publishes both architectures. Pick your track in [Lab 1](docs/01-prerequisites.md).
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

**The other platform services**

17. [Automation Hub](docs/17-hub.md) — galaxy_ng on pulpcore from source, behind the gateway
18. [Event-Driven Ansible](docs/18-eda.md) — eda-server from source, behind the gateway
19. [The platform UI](docs/19-platform-ui.md) — the unified Ansible console (`@ansible/platform-ui`), served by the gateway on 443

**Appendix labs — break it on purpose**

- [A1: The EPEL uwsgi conflict](docs/a1-epel-uwsgi-conflict.md) — deliberately clobber your uwsgi, diagnose the ABI mismatch, armor the box with `excludepkgs`
- [A3: Backup and restore](docs/a3-backup-restore.md) — what actually holds state, and proving you can get it back

— [Glossary](docs/glossary.md) · [Cleanup](docs/99-cleanup.md)

## A note on containers

Everything you build and operate is bare metal. Podman appears only as the **execution-environment sandbox**, on every node that runs work — jobs on the execution plane, project syncs and system jobs on the controller — because an EE *is* a container image and AWX has had no containerless execution since v18. That is the only place podman appears: no service you build runs in a container.

ACE is an independent assembly of upstream community projects — [AWX](https://github.com/ansible/awx), [receptor](https://github.com/ansible/receptor), [jewel](https://github.com/ansible/jewel), [galaxy_ng](https://github.com/ansible/galaxy_ng), and [eda-server](https://github.com/ansible/eda-server) — wired together by hand.

## License

Content is licensed CC BY 4.0 unless noted otherwise.
