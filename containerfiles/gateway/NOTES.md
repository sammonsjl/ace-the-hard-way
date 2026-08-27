# gateway

The platform gateway (jewel) plus the unified console (ansible-ui), in one image.

| | |
|---|---|
| Source | [ansible/jewel](https://github.com/ansible/jewel), [ansible/ansible-ui](https://github.com/ansible/ansible-ui) |
| Base | `quay.io/centos/centos:stream9` |
| Built in | [Lab 5](../../docs/05-gateway.md) |
| Status | **built and running** — see `Containerfile` in this directory |

**Why built rather than pulled:** the published gateway and platform-UI images are both private.

Refs this image was built and verified at (2026-08-27):

```
ARG JEWEL_REF=cd1fd8e657f873f2b7c328cf3acc8696f23fb2ed
ARG ANSIBLE_UI_REF=75d1264624fcf08777f72fcaaeaeb93d9d4a90d1
ARG PYTHON=python3.12
```

Four stages: jewel source → UI build (vite, needs 8 GB of node heap) → venv → runtime (nginx 1.24, supervisor, uwsgi, dumb-init as PID 1, collectstatic baked).

## Built 2026-08-27

Builds clean and runs. One addition beyond jewel's own end state:
`/var/cache/ansible-automation-platform/gateway` must exist in the image, or
Django's file-based fallback cache tries to create it at import time, as a user
that cannot write to `/var/cache`, and every management command fails in system
checks.
