# receptor

The execution mesh node.

| | |
|---|---|
| Source | [ansible/receptor](https://github.com/ansible/receptor) |
| Built in | [Lab 7](../../docs/07-execution.md) |
| Status | **built** (2026-08-27) — `Containerfile` in this directory |

A Go build — the simplest Containerfile in the tutorial, and the one running the hardest lab. Serves 27199 and owns the control socket the controller hands signed work units to.

**Answered 2026-08-27: the image carries its own podman.** Mounting the host's
binary fails at exec with `libsubid.so.6: cannot open shared object file` —
the host binary is linked against libraries the image does not have. receptor
reports this as `Exceeded retries for reading stdout`, because from its side
the work command produced nothing.

ansible-runner is installed here too: receptor's work-command is
`ansible-runner worker`, so the runner lives in receptor's filesystem, not just
in the EE.
