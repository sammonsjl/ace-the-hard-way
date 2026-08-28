# eda

eda-server, built from source.

| | |
|---|---|
| Source | [ansible/eda-server](https://github.com/ansible/eda-server) |
| Base | EL9 |
| Built in | [Lab 9](../../docs/09-eda.md) |
| Status | **built and running** (2026-08-27) |

Four processes: gunicorn on 8000, daphne on 8001, a scheduler and a worker. The only component that reaches Redis over the network port rather than the unix socket.

A usable multi-arch upstream image does exist (`quay.io/ansible/eda-server:main`). This tutorial builds it anyway — an image you did not build is a component you did not learn.

## Corrected 2026-08-28 — layout matched to the vendor

Cross-checked against `eda-controller-rhel9` field by field:

| | vendor | here |
|---|---|---|
| `HOME` | `/var/lib/ansible-automation-platform/eda` | same |
| entry point | `/usr/bin/aap-eda-manage` | same |
| shebang | `#!/usr/bin/python3.12` | same |
| package | `/usr/lib/python3.12/site-packages/aap_eda` | same |
| INSTALLER | `pip` | same |

**There is no venv, and no RPM.** The vendor pip-installs into the system
interpreter — `rpm -qf /usr/bin/aap-eda-manage` reports *"not owned by any
package"*, and the dist-info records `INSTALLER=pip`.

eda-server is a poetry project, but poetry is not required to install it:
`pip install .` reads `pyproject.toml` through PEP 517 and resolves the same
tree. Poetry actively fails here — its dulwich git backend cannot resolve
django-ansible-base from a git ref inside the build.

Two details that make the layout match exactly:

- `pip install --ignore-installed --upgrade pip` first, or any dependency that
  wants to upgrade pip dies with *"Cannot uninstall pip … installed by rpm"*.
- `--prefix=/usr`, not pip's default `/usr/local`, so the package lands in
  `/usr/lib/python3.12/site-packages` and the entry point in `/usr/bin`.
