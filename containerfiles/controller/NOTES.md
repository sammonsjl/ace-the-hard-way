# controller

AWX, built from source.

| | |
|---|---|
| Source | [ansible/awx](https://github.com/ansible/awx) |
| Base | EL9 |
| Built in | [Lab 6](../../docs/06-controller.md) |
| Status | **built and running** (2026-08-27), AWX 25.0.0 |

**Why it must be built:** `quay.io/ansible/awx` is frozen at 24.6.1 (July 2024), predating the gateway / django-ansible-base resource-server integration this platform needs. `ghcr.io/ansible/awx:devel` is an undocumented nightly. The vendor image is private. Pulling any of them makes the tutorial dishonest about its most interesting component.

What it has to contain: the AWX UI built with node and copied into a node-free runtime, a venv with compiled C extensions, receptor and ansible-runner, both supervisord configs (`web` and `task`) hand-written, the `/etc/tower` layout, and an entrypoint that does not call `awx-manage provision_instance` the way the Kubernetes path does.

**Recommended first step:** dissect the real vendor image — entrypoint, supervisord layout, uid, venv path, environment — and write down what it does. Observe the end state; copy nothing.

## Upstream build layout (surveyed 2026-08-27)

AWX does not ship a plain Containerfile. It ships
`tools/ansible/roles/dockerfile/templates/Dockerfile.j2` — 332 lines, rendered
by `make Dockerfile` — plus three supervisor configs that are also templates
(`supervisor_web.conf`, `supervisor_task.conf`, `supervisor_rsyslog.conf`).

Three stages, same shape as the gateway:

| Stage | Does |
|---|---|
| `ui-builder` | centos:stream9, `make ui` — the large npm build |
| `builder` | the venv at `/var/lib/awx/venv/awx`, then `awx-manage collectstatic` |
| runtime | centos:stream9, `pip3.12 install virtualenv supervisor dumb-init build`, supervisor-stdout from a pinned git commit |

Notable: receptor is **copied from a receptor image** (`COPY --from=<receptor_image>
/usr/bin/receptor /usr/bin/receptor`), not built in place — which lines up with
building `containerfiles/receptor/` first and consuming it here.

Rendering the template needs ansible. Writing our own from its end state is the
hard-way route and is what the other images do, but this is the largest of them:
the UI build alone is longer than the gateway's, and the three supervisor
configs have to be written by hand rather than symlinked from a source tree.

## Built 2026-08-27

Builds and runs. Four stages; `make ui` is the longest single step in the
tutorial. `SETUPTOOLS_SCM_PRETEND_VERSION` must be set — a checkout at a bare
commit has no tag for setuptools-scm to derive a version from.

The three supervisor configs in this directory are hand-written from the
production branch of AWX's templates: web (nginx, uwsgi, daphne, ws-heartbeat,
awx-cache-clear), task (dispatcher, callback-receiver, wsrelay), rsyslog
(rsyslogd, configurer).

nginx here is **1.20.1** from AppStream, not the 1.24 module the gateway image
installs, so its config uses `listen ... http2` and not `http2 on;`.
