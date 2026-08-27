# gateway

The platform gateway (jewel) plus the unified console (ansible-ui), in one image.

| | |
|---|---|
| Source | [ansible/jewel](https://github.com/ansible/jewel), [ansible/ansible-ui](https://github.com/ansible/ansible-ui) |
| Base | `quay.io/centos/centos:stream9` |
| Built in | [Lab 5](../../docs/05-gateway.md) |
| Status | not written — working reference exists in `ace-images/gateway/Containerfile` |

**Why built rather than pulled:** the published gateway and platform-UI images are both private.

Known refs from the reference build (verify before reusing — they are from 2026-07):

```
ARG JEWEL_REF=cd1fd8e657f873f2b7c328cf3acc8696f23fb2ed
ARG ANSIBLE_UI_REF=75d1264624fcf08777f72fcaaeaeb93d9d4a90d1
ARG PYTHON=python3.12
```

Four stages: jewel source → UI build (vite, needs 8 GB of node heap) → venv → runtime (nginx 1.24, supervisor, uwsgi, dumb-init as PID 1, collectstatic baked).
