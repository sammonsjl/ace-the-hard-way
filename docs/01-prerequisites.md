# Lab 1 — Prerequisites

## What you'll have at the end

A laptop ready to run the five lab VMs.

## What you need

| | |
|---|---|
| **RAM** | **16 GB minimum.** `terraform/variables.tf` allocates 14.3 GB across five VMs and leaves ~1.5 GB for the host. More is better and the numbers are easy to raise; less will not work. |
| **Disk** | ~60 GB free. Five Rocky VMs, four source checkouts, a node_modules tree and a container image. |
| **CPU** | 4 cores is workable, 8 is comfortable. Two of the builds are long compiles. |
| **Network** | The VMs pull from GitHub, PyPI, npm, quay.io and the Rocky mirrors. Nothing here works air-gapped. |

Everything runs on one machine — the five VMs are a *topology*, not five computers.

## Platform

**Linux on x86_64, with KVM.** The lab is built by Terraform driving libvirt directly, so the
host has to be a machine that can run KVM.

| Your platform | Status |
|---|---|
| Linux (x86_64) with KVM | ✅ full run, amd64 (tested on an Arch host) |
| macOS, Windows | ❌ not supported — see below |

> **If you are on macOS or Windows**, run this on a Linux box: a spare machine, a homelab
> hypervisor, or a cloud VM that supports nested virtualization. There is no macOS path.
> `dmacvicar/libvirt` talks to libvirt, and libvirt/KVM is Linux-only — the provider publishes a
> darwin binary, but only so a Mac can drive a *remote* Linux libvirt host, which is not the
> single-laptop shape this tutorial is built around.
>
> This is a deliberate trade. An earlier version of this lab used Vagrant, which did support
> VMware Fusion on macOS. See [Why Terraform and not Vagrant?](#why-terraform-and-not-vagrant)
> for what that bought and what it cost.

## Install the tools

You need the virtualization stack, Terraform, and `virtiofsd` (which shares this repo into the
VMs).

*Arch* — the host this was tested on:

```bash
sudo pacman -S --needed qemu-full libvirt dnsmasq dmidecode virtiofsd terraform
```

> **Don't add `ebtables` to that line.** It is no longer its own Arch package — `/usr/bin/ebtables`
> ships in `iptables` now, which libvirt already depends on. pacman aborts the *entire* transaction
> on a single unknown target, so one bad name means nothing gets installed.

*Fedora / RHEL family* — package names are correct, but this wasn't tested as a **host** (the guest
VMs are Rocky, so the tutorial's own `dnf` commands are covered — this line is just host prep):

```bash
sudo dnf -y install qemu-kvm libvirt virt-install dnsmasq dmidecode virtiofsd terraform
```

If `terraform` isn't in your repos, add [HashiCorp's dnf repo](https://developer.hashicorp.com/terraform/install)
or drop the release binary on your `PATH`.

*Ubuntu / Debian* — package names are correct, untested as a host:

```bash
sudo apt update
sudo apt install -y qemu-kvm libvirt-daemon-system libvirt-clients dnsmasq dmidecode virtiofsd
```

Terraform is not in Debian/Ubuntu's own repos — use
[HashiCorp's apt repo](https://developer.hashicorp.com/terraform/install).

Then, on any distro:

```bash
sudo systemctl enable --now libvirtd
sudo usermod -aG libvirt "$USER"     # log out/in for the group to take effect

# The lab builds its disks in libvirt's default storage pool.
sudo virsh pool-start default        # harmless if it is already running
sudo virsh pool-autostart default
```

`terraform` may be replaced with `tofu` (OpenTofu) throughout — the configuration uses nothing
proprietary to either.

### An SSH key for the lab

Terraform injects a public key into all five VMs. Use a dedicated one so lab machines never see
your everyday key:

```bash
ssh-keygen -t ed25519 -N '' -C 'ace-the-hard-way lab key' -f ~/.ssh/ace_lab_ed25519
```

Keep it at that path, or point `ssh_public_key_path` in `terraform/variables.tf` somewhere else.

> **Keep the private key on local disk**, even if this repo lives on a NAS. `ssh` refuses a key it
> does not believe you own, and a network filesystem often presents files under a different uid
> than your local account. `~/.ssh` on the host is the right place; the default above already does
> this.

### Host-side things worth knowing

Most are distro or firewall specific — you may hit none of them.

- **Firewall on the libvirt bridge.** If the VMs get no DHCP, or come up but can't reach each other
  on `192.168.56.0/24`, a default-drop firewall (ufw, or Docker's rules) is blocking libvirt's
  bridge. Bridge numbers are handed out in creation order, so don't guess — allow the whole family
  at once:

  ```bash
  sudo ufw allow in on 'virbr+'
  sudo ufw route allow in on 'virbr+'
  sudo ufw route allow out on 'virbr+'
  ```

  `virbr+` is an iptables prefix wildcard, so those three rules cover every libvirt bridge you have
  now or create later. To see what you actually got:

  ```bash
  sudo virsh net-list --all      # the networks libvirt knows about
  ip -br link show type bridge   # the bridges they created
  ```

  Unlike the Vagrant version of this lab, there is only **one** network here (`ace-lab`), carrying
  both SSH and lab traffic.

- **`libvirtd` won't start on a TPM box.** If `virt-secret-init-encryption.service` aborts, seal the
  key to the host instead of the TPM:
  `systemd-creds encrypt --with-key=host --name=secrets-encryption-key - /var/lib/libvirt/secrets/secrets-encryption-key`.

- **This repo may live on a NAS.** Unlike the Vagrant version, that now works. `virtiofsd` serves
  the directory to the guests rather than re-exporting it over NFS, so a network-mounted clone is
  fine. Two caveats: the daemon runs as root, so the export must not squash root; and inside the VM
  the share carries the *host's* ownership, so unprivileged writes may be refused. Every lab that
  writes to the share does so with `sudo`, which is why this doesn't bite in practice.

## Verify

```bash
terraform version
virsh --connect qemu:///system version
virsh --connect qemu:///system pool-info default   # want: State: running
ls /usr/lib/virtiofsd || ls /usr/libexec/virtiofsd  # path varies by distro
```

## Why VMs?

Because this tutorial builds everything **bare metal**: real systemd units, real users, real config
files on a real Linux system. That needs disposable Linux machines you can break and rebuild. It
also matches what you'd run in a homelab or datacenter.

**And why five of them?** Because the seams are the lesson. On one box, "the controller talks to the
database" is a unix socket and a shrug; across five, it is a hostname, a port, a firewall rule and a
certificate whose SAN has to match — and when it breaks you find out which. [Lab 2](02-vms.md) lays
out the topology and why each component gets its own machine.

## Why Terraform and not Vagrant?

This lab used to be a `Vagrantfile`, and Vagrant is genuinely good at exactly this job. Two things
moved it.

**The box registry is going away.** Vagrant the CLI is fine and not deprecated — but the lab pulled
`bento/rockylinux-9` from the Vagrant public registry, and HashiCorp is retiring the hosted service:
no new boxes after **2026-12-14**, end of support **2027-03-15**, decommissioned **2027-06-07**. A
tutorial you might follow in 2027 shouldn't have that on its critical path. The Rocky 9 GenericCloud
image this lab now downloads comes straight from `dl.rockylinux.org`.

**The result is closer to the real thing.** Cloud images and cloud-init are how these machines get
built everywhere else — a homelab, a hypervisor, a cloud account. The VM definitions are declarative
and diffable, one network instead of two, and `terraform destroy` is exact about what it removes.

What it cost: **macOS support**. The Vagrant version ran on VMware Fusion; this one is Linux/KVM
only. If that trade doesn't work for you, the `Vagrantfile` is still in the repo history.

Next: [Provisioning the VMs](02-vms.md)
