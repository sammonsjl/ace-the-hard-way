# eda

eda-server, built from source.

| | |
|---|---|
| Source | [ansible/eda-server](https://github.com/ansible/eda-server) |
| Base | EL9 |
| Built in | [Lab 9](../../docs/09-eda.md) |
| Status | not written — no reference build exists |

Four processes: gunicorn on 8000, daphne on 8001, a scheduler and a worker. The only component that reaches Redis over the network port rather than the unix socket.

A usable multi-arch upstream image does exist (`quay.io/ansible/eda-server:main`). This tutorial builds it anyway — an image you did not build is a component you did not learn.
