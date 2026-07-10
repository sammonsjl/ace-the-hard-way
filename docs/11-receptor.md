# Lab 11 — Receptor

## What you will have at the end

The receptor mesh node from an official release binary — true kubernetes-the-hard-way style.

## Outline (to be written)

- [ ] Download the receptor release tarball (single Go binary — finally, a real tar file!)
- [ ] `receptor.conf`: control socket + work signing (mirror what AWX expects)
- [ ] `receptor.service` unit, dedicated user, socket permissions shared with the awx user
- [ ] Verify: `receptorctl status` works; AWX dispatcher can submit local work

Next: [The execution plane](12-execution-plane.md)
