# Lab 1 — Prerequisites

## What you'll have at the end

A Proxmox node ready to run the five lab VMs, and a workstation that can drive it with Terraform.

## What you need

### The Proxmox host

| | |
|---|---|
| **Proxmox VE** | **8.4 or newer.** The configuration imports a downloaded cloud image straight into a VM disk, which needs the `import` content type. That landed in 8.4. Built and tested on 9.2. |
| **RAM** | **32 GB comfortable.** `terraform/variables.tf` allocates 23 GB across five VMs. It also ships the laptop-scale numbers (14 GB total) as a comment — use those and 16 GB is workable, at the cost of the console build leaning on swap in [Lab 5](05-gateway.md). |
| **Disk** | ~150 GB free on the VM datastore. Five 60 GiB disks, but thin-provisioned: they start near empty and grow to roughly 15–20 GB each as you build. On thick storage, budget the full 300 GB. |
| **CPU** | 4 cores workable, 8 comfortable. The configuration asks for 14 vCPU across the five VMs, which deliberately overcommits — the nodes idle most of the time, and the two long compiles are on different machines. |
| **Network** | A bridge onto a network with DHCP-free space you control, and outbound internet. The VMs pull from GitHub, PyPI, npm, quay.io and the Fedora mirrors. Nothing here works air-gapped. |

### Your workstation

Terraform, an SSH client, and network reach to the Proxmox API. That is all — **any OS**.

This is the one advantage of building on a hypervisor you don't sit in front of: nothing is
compiled, virtualised or mounted locally, so macOS and Windows are as good a driving seat as Linux.
The five VMs are a *topology*, and it lives on the Proxmox node, not on your desk.

## Prepare the Proxmox host

### Two content types the stock install doesn't enable

Terraform needs to put two kinds of file on the node, and a stock Proxmox install allows neither on
the `local` datastore:

- **`snippets`** — the cloud-init user-data for each VM. Proxmox can generate cloud-init itself from
  a username and a key, but that form can only create a user; it cannot install a package or write a
  file. These nodes need both, so the whole document is uploaded as a snippet instead.
- **`import`** — the downloaded Fedora cloud image, which becomes the VM disks.

In the web UI: **Datacenter → Storage → `local` → Edit**, and tick **Snippets** and **Import**
alongside whatever is already selected. Or from a root shell on the node:

```bash
pvesm set local --content vztmpl,iso,import,snippets,backup
```

Check it took:

```bash
pvesm status --content snippets
pvesm status --content import
```

`local` should appear in both. If you keep images on a different datastore, point
`image_datastore_id` and `snippet_datastore_id` at it in `terraform.tfvars` instead — the snippets
one has to be a *directory-backed* store, so `local-lvm` cannot hold it.

### An API token

Terraform authenticates to the API with a token rather than a password. On the node:

```bash
pveum user token add root@pam ace --privsep 0
```

That prints the secret **once** — copy it. `--privsep 0` gives the token the same rights as the user
that owns it, which for `root@pam` is everything. A production build would create a role with only
the privileges this configuration needs and a non-root user to hold it; for a lab you will destroy
next week, the root token is the honest shortcut.

You want the full `user@realm!tokenid=uuid` string, e.g.
`root@pam!ace=6f1e...`.

### SSH to the node

The provider also needs SSH to the Proxmox host as root. This is not belt-and-braces: uploading a
snippet writes a *file* on the node, and there is no API call that does it. Everything else this
configuration does is API-only.

Either set a password in `terraform.tfvars`, or — better — put your key on the node and let the
agent handle it:

```bash
ssh-copy-id root@your-proxmox-host
```

then set `proxmox_ssh_agent = true` and leave `proxmox_ssh_password` unset.

### Addresses

The five VMs take **static** addresses on your bridge. Pick five consecutive ones that are free and
**outside your router's DHCP pool** — if the pool can hand out `.40`, something else will
eventually take it and you will be debugging a duplicate address halfway through Lab 6.

The defaults in `terraform/variables.tf` are `192.168.1.40`–`.44` with a gateway of `192.168.1.1`.
Change them there, or in `terraform.tfvars`, to match your LAN. Whatever you choose, the addresses
appear in `/etc/hosts` on every node and in the certificate SANs from [Lab 3](03-internal-ca.md)
onward, so settle them now rather than later.

> **These VMs are on your home network.** A hypervisor's private NAT network is a sealed box; a
> bridge is not. The nodes can reach — and be reached by — everything else you own. Two labs care
> about this and say so at the time: [Lab 4](04-postgresql.md) writes one `pg_hba.conf` rule per
> client instead of a subnet rule, and [Lab 6](06-controller.md) opens redis to exactly one address.
> Follow those as written; the subnet-wide shortcuts are wrong here.

## Install Terraform

On your workstation only — nothing is installed on the Proxmox node.

*Arch:*

```bash
sudo pacman -S --needed terraform
```

*Fedora / RHEL family:*

```bash
sudo dnf -y install terraform
```

If it isn't in your repos, add [HashiCorp's dnf repo](https://developer.hashicorp.com/terraform/install)
or drop the release binary on your `PATH`.

*Debian / Ubuntu:* not in the distro repos — use
[HashiCorp's apt repo](https://developer.hashicorp.com/terraform/install).

*macOS:*

```bash
brew install terraform
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
> than your local account. `~/.ssh` on your workstation is the right place; the default above
> already does this.

## Configure

```bash
cd terraform
cp terraform.tfvars.example terraform.tfvars
```

Fill in the endpoint, the token, the SSH credentials and your node name. `terraform.tfvars` is
gitignored; the `.example` is not, so keep real credentials out of the latter.

## Verify

```bash
terraform version
```

Then check the API answers and the node is what you think it is — substitute your own endpoint and
token:

```bash
curl -sk -H "Authorization: PVEAPIToken=root@pam!ace=YOUR-SECRET" \
  https://your-proxmox-host:8006/api2/json/version
```

A JSON blob with a `version` of 8.4 or higher means the token works, the endpoint is right, and the
release is new enough. A `401` means the token string is wrong — it must be the whole
`user@realm!tokenid=uuid`, not just the uuid.

## Why VMs?

Because this tutorial builds everything **bare metal**: real systemd units, real users, real config
files on a real Linux system. That needs disposable Linux machines you can break and rebuild. It
also matches what you'd run in a homelab or datacenter.

**And why five of them?** Because the seams are the lesson. On one box, "the controller talks to the
database" is a unix socket and a shrug; across five, it is a hostname, a port, a firewall rule and a
certificate whose SAN has to match — and when it breaks you find out which. [Lab 2](02-vms.md) lays
out the topology and why each component gets its own machine.

## Why Terraform and cloud images?

Cloud images and cloud-init are how these machines get built everywhere else — a homelab, a
hypervisor, a cloud account. The VM definitions are declarative and diffable, and
`terraform destroy` is exact about what it removes. The Fedora Cloud Base image this lab downloads
is chosen from Fedora's own release index and verified against the SHA-256 published there.

> **The lab follows Fedora forward.** Left alone, every `terraform apply` builds on the newest
> stable Fedora, which is the point: this tutorial tracks the upstream of the enterprise
> distributions rather than trailing them. When a new Fedora lands mid-build and you would rather
> not move, `terraform output base_image` prints the release number to pin in
> `terraform.tfvars`.

Next: [Provisioning the VMs](02-vms.md)
