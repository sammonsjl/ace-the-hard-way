# Lab 1 — Prerequisites

## What you'll have at the end

A laptop ready to run the two lab VMs.

## Install the tools

Pick the track for your platform — both are fully tested end-to-end.

**Linux — KVM/libvirt** (`vagrant-libvirt`, no license, all open source). Install the virtualization stack plus Vagrant for your distro, then run the common steps below.

*Arch* — the host this was tested on:

```bash
sudo pacman -S --needed qemu-desktop libvirt dnsmasq ebtables dmidecode nfs-utils vagrant
```

*Fedora / RHEL family* — package names are correct, but this wasn't tested as a **host** (the guest VMs are Rocky, so the tutorial's own `dnf` commands are covered — this line is just the host prep):

```bash
sudo dnf -y install qemu-kvm libvirt virt-install dnsmasq dmidecode nfs-utils vagrant vagrant-libvirt
```

*Ubuntu / Debian* — package names are correct, untested as a host:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq \
  dmidecode nfs-kernel-server vagrant vagrant-libvirt
```

> Distro Vagrant packages can lag; for a current release, install Vagrant from [HashiCorp's apt/dnf repo](https://developer.hashicorp.com/vagrant/install) instead of the distro package.

Then, on any distro:

```bash
sudo systemctl enable --now libvirtd nfs-server   # Ubuntu/Debian: the unit is nfs-kernel-server
sudo usermod -aG libvirt "$USER"                  # log out/in for the group to take effect
vagrant plugin install vagrant-libvirt            # skip if you installed it from your distro repo (Fedora/Ubuntu above)
```

**macOS (Apple Silicon or Intel) — VMware Fusion:**

```bash
brew install --cask vagrant
brew install --cask vagrant-vmware-utility
vagrant plugin install vagrant-vmware-desktop
```

VMware Fusion is a direct download from the [Broadcom support portal](https://support.broadcom.com) (free account, no license key — Fusion is free for personal and commercial use).

## Provider matrix (pick yours)

| Your platform | Provider | Box | Status |
|---|---|---|---|
| Linux (x86_64) | libvirt/KVM (`vagrant-libvirt`) | `bento/rockylinux-9` (default) | ✅ full 19-lab run, amd64 (tested on an Arch host) |
| macOS (Apple Silicon or Intel) | VMware Fusion (`vagrant-vmware-desktop`) | `bento/rockylinux-9` | ✅ full 19-lab run, what the author develops on |
| Windows / Linux (x86_64) | VMware Workstation Pro (`vagrant-vmware-desktop`) — free, same plugin | `bento/rockylinux-9` | untested, should work |
| Windows / Linux (x86_64) | VirtualBox | `bento/rockylinux-9` | untested, should work |

The Vagrantfile carries provider blocks for all of these, and the box is overridable via the `VAGRANT_BOX` env var. `bento/rockylinux-9` publishes libvirt, VMware, and VirtualBox images for both x86_64 and aarch64, so the same default box works on every tested provider. Everything from Lab 2 onward happens INSIDE the Rocky VMs — identical on every platform. If a provider combination misbehaves, please open an issue.

### libvirt/KVM notes (Linux)

The full tutorial was run to completion on KVM/amd64; a few host-side things are worth knowing up front (most are distro/firewall-specific — you may hit none of them):

- **Synced folder is NFS.** `vagrant-libvirt` shares `/vagrant` over NFS and edits `/etc/exports` via `sudo`. The Vagrantfile already pins `nfs_version: 4, nfs_udp: false` because modern Rocky guests reject the plugin's default `vers=3,udp` ("an incorrect mount option was specified"). If Vagrant prompts for a password mid-`up`, add a scoped `/etc/sudoers.d` drop-in for the `exportfs`/`mount`/`systemctl` NFS commands it runs.
- **Keep the repo on local disk** (almost everyone already does — skip this bullet unless your home directory is network-mounted). If your clone lives on an NFS mount itself (e.g. a NAS-backed home), two things break: the kernel can't re-export it for the `/vagrant` share (`exportfs: requires fsid=`), and Vagrant's SSH-key ownership check fails. Clone to a local path and run Vagrant from there. This is unrelated to the NFSv4 mount option above — that one is about how the guest mounts `/vagrant`; this is about where your copy of the repo sits.
- **Firewall on the libvirt bridge.** If the guest gets no DHCP/DNS, a default-drop firewall (ufw, or Docker's rules) is blocking the `virbrN` bridge. Allow it: `ufw allow in on virbr0` plus `ufw route allow in on virbr0 && ufw route allow out on virbr0`.
- **`libvirtd` won't start on a TPM box.** If `virt-secret-init-encryption.service` aborts, seal the key to the host instead of the TPM: `systemd-creds encrypt --with-key=host --name=secrets-encryption-key - /var/lib/libvirt/secrets/secrets-encryption-key`.

## Verify

```bash
vagrant --version
vagrant plugin list        # want: vagrant-libvirt (Linux) or vagrant-vmware-desktop (macOS)
```

## Why VMs?

Because this tutorial builds everything **bare metal**: real systemd units, real users, real config files on a real Linux system. That needs a disposable Linux machine you can break and rebuild — which is exactly what a Vagrant VM is. It also matches what you'd run in a homelab or datacenter.

Next: [Provisioning the VMs](02-vms.md)
