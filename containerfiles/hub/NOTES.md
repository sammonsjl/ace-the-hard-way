# hub

galaxy_ng on pulpcore.

| | |
|---|---|
| Source | [ansible/galaxy_ng](https://github.com/ansible/galaxy_ng) |
| Base | `docker.io/pulp/base` |
| Built in | [Lab 8](../../docs/08-hub.md) |
| Status | **built and running** (2026-08-27) |

**Why built rather than pulled:** the published galaxy-ng image is amd64-only, and `pulp/pulp-galaxy-ng` is abandoned.

Known ref from the reference build (verify before reusing):

```
ARG GALAXY_NG_REF=04335c3a5b3ccf0a501d7c01f8d3965007017cb8
```

Forces `django-ansible-base` to a ref matching the gateway's, so the JWT dialect agrees. That pin needs a manual check against galaxy_ng's own `setup.py` on every refresh — an open question in Lab 8 is whether that can be made mechanical.

## Built 2026-08-27

The dependency story is the lab. galaxy_ng's own pip-compile lockfile is stale
against PyPI — it pins pulpcore==3.49.40 alongside aiohttp and protobuf versions
that pulpcore's published metadata forbids — so it cannot be used as constraints
at all. Installing the pinned closure with `--no-deps` works, because
pip-compile already resolved it. django-ansible-base is overridden to devel to
match the gateway's JWT dialect, and that install needs `--no-deps` too or it
drags in Django 5.x and pulpcore fails at collectstatic.

## Corrected 2026-08-28

Built from `main`, not `master`. `master` is a stale branch (4.11.0dev,
pulpcore 3.49.40) whose lockfile no longer resolves; `main` is the default
branch and gives 4.12.0dev on pulpcore 3.105.12 — the same platform the vendor
ships. Cross-checked against `hub-rhel9`: pulpcore and pulp-ansible match
exactly.

Config parity: named `galaxy` user, WORKDIR /, PYTHONUNBUFFERED=1 (the pulp/base
image sets it to 0, which keeps pulpcore's output out of the journal).
