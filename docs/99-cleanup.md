# Lab 99 — Cleanup

## What you will have at the end

Your laptop back.

## Before you burn it down

Everything you built lives inside the five VMs — destroying them destroys the platform. Two things are worth saving first:

```bash
# your recorded pins: the AWX/ansible-ui/jewel commit SHAs, package versions,
# and the EE digest — they're what makes YOUR build reproducible.
# If you kept them in the repo or your notes, you're done. If they're in
# shell history on the VMs, copy them out now.

# optional: a Lab A2-style backup (SECRET_KEY + pg_dump) if you might resurrect
# this build later instead of rebuilding from Lab 1
```

## Burn it down

From the `terraform/` directory on your laptop:

```bash
cd terraform
terraform destroy
```

That removes all five VMs, their disks, the cloud-init images and the `ace-lab` network — Terraform
knows exactly what it created, so there is nothing to hunt for.

It also removes the downloaded Rocky base image. If you plan to rebuild soon and would rather keep
that ~650 MB download, drop it from state first:

```bash
terraform state rm libvirt_volume.base    # optional — then destroy
```

## Anything on the host?

Almost nothing — that was the point of building inside VMs:

```bash
virsh --connect qemu:///system list --all       # want: no ace-* domains left
virsh --connect qemu:///system net-list --all   # want: no ace-lab
virsh --connect qemu:///system vol-list default # want: no ace-*.qcow2
ls *.crt *.csr 2>/dev/null                      # repo root — Lab 3's cert shuttle files, already tidied
```

Remove the generated `ssh_config` include from `~/.ssh/config` if you added it in
[Lab 2](02-vms.md), and delete the lab key if you won't reuse it:

```bash
rm -f ~/.ssh/ace_lab_ed25519 ~/.ssh/ace_lab_ed25519.pub
```

If you imported the internal CA into your laptop's browser or trust store during Lab 4, remove it — it signed things; don't leave stray CAs installed:

- macOS: Keychain Access → search "ACE Lab CA" → delete
- Firefox: Settings → Certificates → Authorities → remove

The `receptor`/`envoy` binaries, venvs, postgres — all died with the VMs. Nothing else to clean.

Back to the [README](../README.md)
