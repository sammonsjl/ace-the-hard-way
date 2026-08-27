# hub

galaxy_ng on pulpcore.

| | |
|---|---|
| Source | [ansible/galaxy_ng](https://github.com/ansible/galaxy_ng) |
| Base | `docker.io/pulp/base` |
| Built in | [Lab 8](../../docs/08-hub.md) |
| Status | not written — working reference exists in `ace-images/hub/Containerfile` |

**Why built rather than pulled:** the published galaxy-ng image is amd64-only, and `pulp/pulp-galaxy-ng` is abandoned.

Known ref from the reference build (verify before reusing):

```
ARG GALAXY_NG_REF=04335c3a5b3ccf0a501d7c01f8d3965007017cb8
```

Forces `django-ansible-base` to a ref matching the gateway's, so the JWT dialect agrees. That pin needs a manual check against galaxy_ng's own `setup.py` on every refresh — an open question in Lab 8 is whether that can be made mechanical.
