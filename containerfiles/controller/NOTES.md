# controller

AWX, built from source.

| | |
|---|---|
| Source | [ansible/awx](https://github.com/ansible/awx) |
| Base | EL9 |
| Built in | [Lab 6](../../docs/06-controller.md) |
| Status | **does not exist anywhere — the largest piece of work on this branch** |

**Why it must be built:** `quay.io/ansible/awx` is frozen at 24.6.1 (July 2024), predating the gateway / django-ansible-base resource-server integration this platform needs. `ghcr.io/ansible/awx:devel` is an undocumented nightly. The vendor image is private. Pulling any of them makes the tutorial dishonest about its most interesting component.

What it has to contain: the AWX UI built with node and copied into a node-free runtime, a venv with compiled C extensions, receptor and ansible-runner, both supervisord configs (`web` and `task`) hand-written, the `/etc/tower` layout, and an entrypoint that does not call `awx-manage provision_instance` the way the Kubernetes path does.

**Recommended first step:** dissect the real vendor image — entrypoint, supervisord layout, uid, venv path, environment — and write down what it does. Observe the end state; copy nothing.
