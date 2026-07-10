# Lab 1 — Prerequisites

## What you'll have at the end

A laptop ready to run the two lab VMs.

## Install the tools

On macOS (Apple Silicon or Intel):

```bash
brew install --cask vagrant
brew install --cask vagrant-vmware-utility
vagrant plugin install vagrant-vmware-desktop
```

VMware Fusion is a direct download from the [Broadcom support portal](https://support.broadcom.com) (free account, no license key — Fusion is free for personal and commercial use).

## Provider matrix (pick yours)

| Your platform | Provider | Box | Status |
|---|---|---|---|
| macOS (Apple Silicon or Intel) | VMware Fusion (`vagrant-vmware-desktop`) | `bento/rockylinux-9` | ✅ what the author uses |
| Windows / Linux (x86_64) | VMware Workstation Pro (`vagrant-vmware-desktop`) — free, same plugin | `bento/rockylinux-9` | untested, should work |
| Windows / Linux (x86_64) | VirtualBox | `bento/rockylinux-9` | untested, should work |
| Linux (any) | libvirt/KVM (`vagrant-libvirt`) | `generic/rocky9` — set `VAGRANT_BOX=generic/rocky9` | untested, should work |

The Vagrantfile carries provider blocks for all three, and the box is overridable via the `VAGRANT_BOX` env var. Everything from Lab 2 onward happens INSIDE the Rocky VMs — identical on every platform. If a provider combination misbehaves, please open an issue.

## Verify

```bash
vagrant --version
vagrant plugin list        # want: vagrant-vmware-desktop
```

## Why VMs?

Because this tutorial builds everything **bare metal**: real systemd units, real users, real config files on a real Linux system. That needs a disposable Linux machine you can break and rebuild — which is exactly what a Vagrant VM is. It also matches what you'd run in a homelab or datacenter.

Next: [Provisioning the VMs](02-vms.md)
