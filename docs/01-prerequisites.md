# Lab 1 — Prerequisites

## What you'll have at the end

A laptop ready to run the five lab VMs.

## What you need

| | |
|---|---|
| **RAM** | **16 GB minimum.** The `Vagrantfile` allocates 14.3 GB across five VMs and leaves ~1.5 GB for the host. More is better and the numbers are easy to raise; less will not work. |
| **Disk** | ~60 GB free. Five Rocky boxes, four source checkouts, a node_modules tree and a container image. |
| **CPU** | 4 cores is workable, 8 is comfortable. Two of the builds are long compiles. |
| **Network** | The VMs pull from GitHub, PyPI, npm, quay.io and the Rocky mirrors. Nothing here works air-gapped. |

Everything runs on one machine — the five VMs are a *topology*, not five computers.

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
| Linux (x86_64) | libvirt/KVM (`vagrant-libvirt`) | `bento/rockylinux-9` (default) | ✅ full run, amd64 (tested on an Arch host) |
| macOS (Apple Silicon or Intel) | VMware Fusion (`vagrant-vmware-desktop`) | `bento/rockylinux-9` | ✅ full run, what the author develops on |
| Windows / Linux (x86_64) | VMware Workstation Pro (`vagrant-vmware-desktop`) — free, same plugin | `bento/rockylinux-9` | untested, should work |

The Vagrantfile carries provider blocks for libvirt and VMware, and the box is overridable via the `VAGRANT_BOX` env var. `bento/rockylinux-9` publishes libvirt and VMware images for both x86_64 and aarch64, so the same default box works on every tested provider. Everything from Lab 2 onward happens INSIDE the Rocky VMs — identical on every platform. If a provider combination misbehaves, please open an issue.

### libvirt/KVM notes (Linux)

The full tutorial was run to completion on KVM/amd64; a few host-side things are worth knowing up front (most are distro/firewall-specific — you may hit none of them):

- **Synced folder is NFS.** `vagrant-libvirt` shares `/vagrant` over NFS and edits `/etc/exports` via `sudo`. The Vagrantfile already pins `nfs_version: 4, nfs_udp: false` because modern Rocky guests reject the plugin's default `vers=3,udp` ("an incorrect mount option was specified"). If Vagrant prompts for a password mid-`up`, add a scoped `/etc/sudoers.d` drop-in for the `exportfs`/`mount`/`systemctl` NFS commands it runs.
- **Keep the repo on local disk** (almost everyone already does — skip this bullet unless your home directory is network-mounted). If your clone lives on an NFS mount itself (e.g. a NAS-backed home), two things break: the kernel can't re-export it for the `/vagrant` share (`exportfs: requires fsid=`), and Vagrant's SSH-key ownership check fails. Clone to a local path and run Vagrant from there. This is unrelated to the NFSv4 mount option above — that one is about how the guest mounts `/vagrant`; this is about where your copy of the repo sits.
- **Firewall on the libvirt bridges.** If the guest gets no DHCP/DNS, or the VMs come up but can't reach each other on `192.168.56.0/24`, a default-drop firewall (ufw, or Docker's rules) is blocking libvirt's bridges. Note the plural: this lab ends up with **two** networks — vagrant-libvirt's own management network (DHCP and SSH) and the `ace-lab` network the Vagrantfile defines for `192.168.56.0/24` — and neither one is necessarily `virbr0`. Bridge numbers are handed out in creation order, so don't guess; allow the whole family at once:

  ```bash
  sudo ufw allow in on 'virbr+'
  sudo ufw route allow in on 'virbr+'
  sudo ufw route allow out on 'virbr+'
  ```

  `virbr+` is an iptables prefix wildcard, so those three rules cover every libvirt bridge you have now or create later. (Prefer to scope it tighter? Swap `'virbr+'` for a specific bridge name and repeat per bridge.) To see what you actually got:

  ```bash
  sudo virsh net-list --all      # the networks libvirt knows about
  ip -br link show type bridge   # the bridges they created
  ```
- **`libvirtd` won't start on a TPM box.** If `virt-secret-init-encryption.service` aborts, seal the key to the host instead of the TPM: `systemd-creds encrypt --with-key=host --name=secrets-encryption-key - /var/lib/libvirt/secrets/secrets-encryption-key`.

## Verify

```bash
vagrant --version
vagrant plugin list        # want: vagrant-libvirt (Linux) or vagrant-vmware-desktop (macOS)
```

## Why VMs?

Because this tutorial builds everything **bare metal**: real systemd units, real users, real config files on a real Linux system. That needs disposable Linux machines you can break and rebuild — which is exactly what Vagrant VMs are. It also matches what you'd run in a homelab or datacenter.

**And why five of them?** Because the seams are the lesson. On one box, "the controller talks to the database" is a unix socket and a shrug; across five, it is a hostname, a port, a firewall rule and a certificate whose SAN has to match — and when it breaks you find out which. [Lab 2](02-vms.md) lays out the topology and why each component gets its own machine.

Next: [Provisioning the VMs](02-vms.md)
