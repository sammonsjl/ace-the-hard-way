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
| **execution plane** | The layer where jobs actually run. In this tutorial: a VM with receptor + podman. Later: can be Kubernetes via container groups. The control plane never knows the difference. |
| **execution node** | One machine that's a member of the execution plane (`--node_type=execution`). |
| **EE (execution environment)** | The container image a job runs inside — ansible-core + collections + dependencies, frozen. EEs are containers by definition; there's been no containerless execution since AWX 18. |
| **ansible-runner** | The program inside the EE that actually invokes ansible-playbook and streams results back. |
| **hop node** | A receptor relay — no jobs run there; it forwards mesh traffic into isolated networks (v2 topic). |
| **container group** | An execution-plane member that is a Kubernetes cluster: instead of a standing node, the control plane asks k8s to create a pod per job (future chapter). |

## Control-side terms

| Term | Meaning |
|---|---|
| **gateway (Jewel)** | The platform's front door: single login, one URL, proxies to the controller/hub/EDA (Labs 6–7, joined in 16). |
| **envoy** | The proxy the gateway drives — the actual traffic router in front of the platform services. Learns its routes from the gateway over xDS; opens no listener until a service is registered. |
| **awx-manage** | AWX's admin command (Django manage.py in a suit): migrations, users, instance registration, all of Lab 10. |

## The other platform services

| Term | Meaning |
|---|---|
| **Automation Hub (galaxy_ng)** | The content service — collections and execution-environment images. A Django app (`galaxy_ng`) that is a plugin on top of **pulpcore** (Lab 18). |
| **pulpcore** | The content-management engine under the hub: an API server, a content server, and tasking workers, all sharing one postgres + redis. galaxy_ng, pulp-ansible, and pulp-container are plugins on it. |
| **EDA (eda-server)** | Event-Driven Ansible — watches event sources and runs **rulebook activations** (automation triggered by events, not by a human clicking launch) in decision-environment containers (Lab 19). |
| **DAB (django-ansible-base)** | The shared library that carries the platform's JWT and RBAC contract. Every service that sits behind the gateway consumes the gateway's JWT through DAB — which is why their DAB versions must line up (Lab 18's version saga). |
| **JWT SSO** | The gateway authenticates you once, mints a signed JWT describing who you are, and attaches it to every proxied request. Each service's DAB JWT consumer trusts the gateway's signature — so one login reaches the controller, the hub, and EDA alike. |

Back to the [README](../README.md)
