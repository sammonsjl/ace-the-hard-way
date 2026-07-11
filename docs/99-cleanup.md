# Lab 99 — Cleanup

## What you will have at the end

Your laptop back.

## Before you burn it down

Everything you built lives inside the two VMs — destroying them destroys the platform. Two things are worth saving first:

```bash
# your recorded pins: the AWX/ansible-ui/jewel commit SHAs, package versions,
# and the EE digest — they're what makes YOUR build reproducible.
# If you kept them in the repo or your notes, you're done. If they're in
# shell history on the VMs, copy them out now.

# optional: a Lab A3-style backup (SECRET_KEY + pg_dump) if you might resurrect
# this build later instead of rebuilding from Lab 1
```

## Burn it down

From the repo directory on your laptop:

```bash
vagrant destroy -f
vagrant box remove bento/rockylinux-9    # optional — keep it if you'll rebuild
```

## Anything on the host?

Almost nothing — that was the point of building inside Vagrant:

```bash
vagrant global-status --prune     # want: no ace-control / ace-exec entries left
ls /vagrant 2>/dev/null           # (host repo dir) — Lab 12's cert shuttle files were already tidied
```

If you imported the lab CA into your laptop's browser or trust store during Lab 10, remove it — it signed things; don't leave stray CAs installed:

- macOS: Keychain Access → search "ACE Lab CA" → delete
- Firefox: Settings → Certificates → Authorities → remove

The `receptor`/`envoy` binaries, venvs, postgres — all died with the VMs. Nothing else to clean.

Back to the [README](../README.md)
