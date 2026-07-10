# Lab 12 — The execution node

## What you will have at the end

ace-exec running receptor from the release binary, TLS-peered to the control node — a real AAP-style execution node, built by hand.

## Outline (to be written)

- [ ] Receptor release binary on ace-exec (same tarball as Lab 11)
- [ ] Generate the receptor CA + node certs by hand (this is the undocumented dark art — document every step)
- [ ] `receptor.conf` on ace-exec: tcp-listener, TLS server config, work-command for `ansible-runner worker`
- [ ] `receptor.conf` on ace-control: tcp-peer → 192.168.56.20, TLS client config
- [ ] Work signing keypair (control signs, exec verifies)
- [ ] Job sandbox: `dnf install podman` + pull an EE image (`quay.io/ansible/awx-ee`)
- [ ] Verify: `receptorctl status` on ace-control shows the mesh, both nodes, advertised work types

> **Why podman appears here and only here:** an execution environment IS a container image — since AWX 18 there is no containerless job execution. On a real AAP execution node, receptor (bare metal, yours) hands the job to ansible-runner, which runs it inside the EE under podman. You built the node; podman is just the job sandbox.

## From the real installer (2.6 RPM bundle)

- [ ] **firewalld:** receptor listener is `27199/tcp` — open it on ace-exec or the mesh times out silently
- [ ] Receptor certs are signed by the platform CA and verified against it (matches our plan; use the CA from Lab 10)
- [ ] Installer validates: receptor datadir writable by the receptor user, not on tmpfs (or gets a tmpfiles.d entry), peer names DNS-resolvable — adopt all three as verify steps

Next: [Instance registration](13-instance-registration.md)
