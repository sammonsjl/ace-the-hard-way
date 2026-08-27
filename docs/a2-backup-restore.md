# Appendix A2 — Backup and restore

> **Not written yet.** Goal and outline below; unchecked boxes are undone.

## What you will have at the end

A restore you actually performed, and a clear answer to the question the bare-metal version of this appendix also asks: what is state, and what is just reconstructible?

## Where it fits

Containers change the shape of this question rather than the answer. On bare metal, state is scattered across a filesystem and you have to know which directories matter. Here the boundary is explicit — a container's filesystem is disposable by construction, and anything that must survive is a volume or a mount you chose.

That makes the accounting easier and the discipline stricter: if it is not in a volume or under `~/ace/`, it does not survive `podman rm`, and you find that out at the worst possible time.

## Outline

- [ ] The inventory: four PostgreSQL databases, hub's artifact storage, the CA and every certificate, every config file under `~/ace/`, the podman secrets
- [ ] **podman secrets are not files you can copy.** Where they actually live and how to back them up — or whether the honest answer is to regenerate them and re-register
- [ ] `pg_dump` from inside the container vs from the host
- [ ] Hub's content: what pulp stores, and whether it is worth backing up or worth re-syncing
- [ ] What is explicitly *not* state: every image (rebuildable from a pinned ref), every container, the extracted trust bundle (regenerated in one command)
- [ ] The restore, performed on a clean host — the only version of this appendix worth writing
- [ ] Verify: a job template that ran before the backup runs after the restore

Next: [Cleanup](99-cleanup.md)
