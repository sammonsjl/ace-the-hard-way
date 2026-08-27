# Glossary — who's who in the process family

Every process you'll build, one line each. Come back here whenever a name goes blurry.

## The web pair

| Process | What it does |
|---|---|
| **uwsgi** | Answers normal API/web requests (WSGI): request in, response out, connection closes. *Ask and answer.* |
| **daphne** | Holds the long-lived websocket connections (ASGI) — live job output streaming into your browser is daphne. *Stays on the line.* |

nginx sits in front and sorts: `/websocket/` paths → daphne's socket, everything else → uwsgi's socket, static files served directly.

| Term | Meaning |
|---|---|
| **WSGI** | *Web Server Gateway Interface* — Python's standard plug between a web server and an app. Synchronous: one request in, one response out, connection closes. What uwsgi speaks. |
| **ASGI** | *Asynchronous Server Gateway Interface* — WSGI's async successor, built for connections that stay open (websockets, long polling). What daphne speaks. |

Same Django app, two plugs — that's why AWX needs two web servers.

## The workers

| Process | What it does |
|---|---|
| **dispatcher** | The task engine. Picks up launched jobs and decides where they run — hands work to receptor. The process that talks to the execution plane. |
| **callback receiver** | Ingests job events (every task result from every playbook run) and writes them to the database. High-volume worker. |
| **wsrelay** | Relays events between nodes so websocket clients get updates no matter which web node they're connected to. |
| **ws-heartbeat** | Keeps node websocket connections advertised and fresh — the pulse of the websocket subsystem. |

## The plumbing

| Process | What it does |
|---|---|
| **rsyslogd** (+ **rsyslog-configurer**) | External logging relay — ships AWX logs to outside aggregators (Splunk etc.). Runs under supervisord alongside the other AWX processes, with a helper that rewrites its config when settings change. |
| **supervisord** | The process manager babysitting all of the above. systemd starts it (`automation-controller.service`); it starts everything else. |
| **receptor** | The work mesh. A single Go binary on every node; control nodes hand it work, it moves the work (TLS, signed) to whichever node should run it. |

## Execution-side terms

| Term | Meaning |
|---|---|
| **execution plane** | The layer where jobs actually run. On this track: a receptor container that starts EE containers of its own. Later: can be Kubernetes via container groups. The control plane never knows the difference. |
| **execution node** | One machine that's a member of the execution plane (`--node_type=execution`). |
| **EE (execution environment)** | The container image a job runs inside — ansible-core + collections + dependencies, frozen. EEs are containers by definition; there's been no containerless execution since AWX 18. |
| **ansible-runner** | The program inside the EE that actually invokes ansible-playbook and streams results back. |
| **hop node** | A receptor relay — no jobs run there; it forwards mesh traffic into isolated networks (v2 topic). |
| **container group** | An execution-plane member that is a Kubernetes cluster: instead of a standing node, the control plane asks k8s to create a pod per job (future chapter). |

## Control-side terms

| Term | Meaning |
|---|---|
| **gateway (Jewel)** | The platform's front door: single login, one URL, proxies to the controller/hub/EDA (Labs 5–7, joined in 16). |
| **envoy** | The proxy the gateway drives — the actual traffic router in front of the platform services. Learns its routes from the gateway over xDS; opens no listener until a service is registered. |
| **awx-manage** | AWX's admin command (Django manage.py in a suit): migrations, users, instance registration, all of Lab 5. |

## The other platform services

| Term | Meaning |
|---|---|
| **Automation Hub (galaxy_ng)** | The content service — collections and execution-environment images. A Django app (`galaxy_ng`) that is a plugin on top of **pulpcore** (Lab 5). |
| **pulpcore** | The content-management engine under the hub: an API server, a content server, and tasking workers, all sharing one postgres + redis. galaxy_ng, pulp-ansible, and pulp-container are plugins on it. |
| **EDA (eda-server)** | Event-Driven Ansible — watches event sources and runs **rulebook activations** (automation triggered by events, not by a human clicking launch) in decision-environment containers (Lab 6). |
| **DAB (django-ansible-base)** | The shared library that carries the platform's JWT and RBAC contract. Every service that sits behind the gateway consumes the gateway's JWT through DAB — which is why their DAB versions must line up (Lab 5's version saga). |
| **JWT SSO** | The gateway authenticates you once, mints a signed JWT describing who you are, and attaches it to every proxied request. Each service's DAB JWT consumer trusts the gateway's signature — so one login reaches the controller, the hub, and EDA alike. |

## Containers, on this track

| Term | Meaning |
|---|---|
| **Containerfile** | The build recipe for an image. Identical in syntax to a Dockerfile; the name is podman's. On this track it is the lab — the thing you write instead of typing install commands into a shell. |
| **quadlet** | A `.container` file in `~/.config/containers/systemd/` that systemd's podman generator turns into a service unit at `daemon-reload`. `ace-thing.container` becomes `ace-thing.service`. Replaces the deprecated `podman generate systemd`. |
| **user unit** | A systemd unit owned by your login rather than by root — `systemctl --user`, not `systemctl`. Everything in this tutorial is one. Needs **lingering** enabled to survive logout or start at boot. |
| **lingering** | `loginctl enable-linger` — keeps your systemd user manager running when you are not logged in. Without it the entire platform stops when your session ends. |
| **rootless** | podman running as your own account, with no daemon and no root. Containers get a user namespace mapped out of your **subuid/subgid** range. |
| **`userns: keep-id`** | Maps the container's user to *your* UID instead of into the subuid range, so files a container writes to a mounted directory belong to you. Used everywhere here except PostgreSQL, whose official image has its own uid-999 machinery. |
| **podman secret** | A value podman stores outside the image and injects at run time, so passwords and keys never land in a layer or a config file in the repo. |
| **extracted trust bundle** | `~/ace/tls/extracted/` — the output of running `update-ca-trust` once in a throwaway EL9 container, mounted into every service container. It is how images built long before your CA existed come to trust it (Lab 3). |
| **`:Z`** | A mount suffix asking podman to relabel a file so SELinux lets the container read it. Mandatory on RHEL-family hosts, silently ignored elsewhere. The labs write it everywhere it belongs so the same command works on either. |
| **`%h`** | systemd's specifier for your home directory. Quadlets are not shells — `$HOME` and `~` do not expand in them. |
| **EE / DE** | *Execution environment* and *decision environment* — container images carrying ansible-core plus collections, and ansible-rulebook plus its dependencies. A job runs in an EE; a rulebook activation runs in a DE. |

Back to the [README](../README.md)
