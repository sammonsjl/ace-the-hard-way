# Lab 99 — Cleanup

## What you will have at the end

Your Proxmox node back.

## Before you burn it down

Everything you built lives inside the five VMs — destroying them destroys the platform. Two things are worth saving first:

1. **Your recorded pins** — the AWX, ansible-ui and jewel commit SHAs, the package versions, and the
   EE digest. They are what makes *your* build reproducible. If you kept them in the repo or your
   notes, you are done; if they only exist in shell history on the VMs, copy them out now.
2. **A Lab A2-style backup** (`SECRET_KEY` + `pg_dump`), optional — worth it only if you might
   resurrect this build later instead of rebuilding from Lab 1.

## Burn it down

From the `terraform/` directory on your workstation:

```bash
cd terraform
terraform destroy
```

That removes all five VMs, their disks and their cloud-init snippets — Terraform knows exactly what
it created, so there is nothing to hunt for.

It also removes the downloaded Fedora base image from the node. If you plan to rebuild soon and
would rather keep that ~557 MB download, drop it from state first:

```bash
terraform state rm proxmox_download_file.base
```

Terraform then leaves it in place, and the next `apply` adopts it rather than re-downloading.

## Anything left on the Proxmox node?

Almost nothing — that was the point of building inside VMs. From a root shell on the node:

```bash
qm list
pvesm list local --content snippets
pvesm list local --content import
```

`qm list` should show none of `140`–`144`. Anything left under `snippets` named `ace-*-user-data.yaml`,
or an `ace-fedora-*.qcow2` under `import`, is a leftover you can delete — though if you dropped the
image from state above, that last one is deliberate. More than one `ace-fedora-*.qcow2` means you
have rebuilt across a Fedora release; the older one is safe to remove.

The API token and the two content types you enabled in [Lab 1](01-prerequisites.md) are still there.
Leave them if you might rebuild; otherwise:

```bash
pveum user token remove root@pam ace
```

Remove the generated `ssh_config` include from `~/.ssh/config` if you added it in
[Lab 2](02-vms.md), and delete the lab key if you won't reuse it:

```bash
rm -f ~/.ssh/ace_lab_ed25519 ~/.ssh/ace_lab_ed25519.pub
```

If you imported the internal CA into your browser or trust store during Lab 4, remove it — it signed things; don't leave stray CAs installed:

- macOS: Keychain Access → search "ACE Lab CA" → delete
- Firefox: Settings → Certificates → Authorities → remove

The `receptor`/`envoy` binaries, venvs, postgres — all died with the VMs. Nothing else to clean.

Back to the [README](../README.md)
