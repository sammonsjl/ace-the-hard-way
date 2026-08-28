# receptor

The execution mesh node.

| | |
|---|---|
| Source | [ansible/receptor](https://github.com/ansible/receptor) |
| Built in | [Lab 7](../../docs/07-execution.md) |
| Status | **built** (2026-08-27) — `Containerfile` in this directory |

A Go build — the simplest Containerfile in the tutorial, and the one running the hardest lab. Serves 27199 and owns the control socket the controller hands signed work units to.

Open question for Lab 7: the vendor's installer mounts the *host's* podman binary into this container rather than shipping one. Whether that is the right shape here or whether the image should carry its own is undecided.
