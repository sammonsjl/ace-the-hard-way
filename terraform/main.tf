# ACE the Hard Way — lab environment
#
# Five VMs, mirroring the shape of a distributed RPM deployment:
#
#   ace-db          .10   PostgreSQL, alone on its own host
#   ace-gateway     .11   platform gateway + colocated Redis + envoy + the console
#   ace-controller  .12   AWX — a HYBRID node, so it also runs jobs in EE containers
#   ace-hub         .13   automation hub (galaxy_ng on pulpcore)
#   ace-eda         .14   Event-Driven Ansible
#
# A real deployment of this shape adds a sixth VM — a dedicated execution node —
# and keeps the controller control-only. We fold that role into the controller by
# making it a hybrid node, which is the one deliberate departure and saves a VM.
#
# Sizing and node addresses live in variables.tf.

locals {
  ssh_pubkey = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # The repo root — the directory holding this terraform/ directory. Shared into
  # every VM at var.share_mount.
  repo_dir = abspath("${path.module}/..")

  # Rendered into /etc/hosts on every node, as quoted printf arguments.
  hosts_entries = join(" ", [
    for name, n in var.nodes : "'${n.ip} ${name}'"
  ])
}

# One network for all five: SSH and lab traffic share a single subnet, so there
# is only one place to look when a firewall rule is wrong.
resource "libvirt_network" "lab" {
  name      = var.network_name
  autostart = true
  forward   = { mode = "nat" }
  dns       = { enable = "yes" }

  ips = [{
    family  = "ipv4"
    address = var.gateway_ip
    netmask = cidrnetmask(var.network_cidr)

    # Addresses are pinned by MAC rather than configured inside the guest.
    # libvirt's own DHCP hands each node the address the labs expect, so there is
    # no guest-side network config to drift or to guess an interface name for.
    dhcp = {
      ranges = [{ start = cidrhost(var.network_cidr, 100), end = cidrhost(var.network_cidr, 200) }]
      hosts = [
        for name, n in var.nodes : { mac = n.mac, ip = n.ip, name = name }
      ]
    }
  }]
}

# Downloaded once, then used as the backing store for all five overlays.
# `capacity` is ignored when `create.content` is set ("required unless using
# create.content"), so the image lands at its native 10 GiB and the overlays
# below carry the size we actually want.
resource "libvirt_volume" "base" {
  name   = "ace-rocky9-base.qcow2"
  pool   = var.pool
  target = { format = { type = "qcow2" } }
  create = {
    content = { url = var.base_image_url }
  }
}

# A thin copy-on-write overlay per node. cloud-init's growpart then expands the
# root partition to fill it on first boot.
resource "libvirt_volume" "node" {
  for_each = var.nodes

  name          = "${each.key}.qcow2"
  pool          = var.pool
  capacity      = var.disk_size
  capacity_unit = "B"
  target        = { format = { type = "qcow2" } }
  backing_store = {
    path   = libvirt_volume.base.path
    format = { type = "qcow2" }
  }
}

resource "libvirt_cloudinit_disk" "node" {
  for_each = var.nodes

  name = "${each.key}-cloudinit.iso"

  meta_data = <<-EOT
    instance-id: ${each.key}
    local-hostname: ${each.key}
  EOT

  user_data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
    hostname      = each.key
    guest_user    = var.guest_user
    ssh_pubkey    = local.ssh_pubkey
    share_tag     = var.share_tag
    share_mount   = var.share_mount
    hosts_entries = local.hosts_entries
  })
}

resource "libvirt_domain" "node" {
  for_each = var.nodes

  name        = each.key
  type        = "kvm"
  memory      = each.value.memory
  memory_unit = "MiB"
  vcpu        = each.value.vcpu

  # Required. Without it the domain is defined but never started.
  running = true

  # Required. Omit this and the provider emits `acpi=off`, and a q35 guest then
  # hangs before GRUB — no console output, no DHCP, no sign of life at all.
  features = {
    acpi = true
    apic = {}
  }

  os = {
    type         = "hvm"
    type_arch    = "x86_64"
    type_machine = "q35"
  }

  cpu = { mode = "host-passthrough" }

  # virtiofs needs shared memory backing for the vhost-user connection to
  # virtiofsd. Without it the share simply does not appear.
  memory_backing = {
    memory_source = { type = "memfd" }
    memory_access = { mode = "shared" }
  }

  devices = {
    disks = [
      {
        device = "disk"
        driver = { name = "qemu", type = "qcow2" }
        source = { volume = { pool = var.pool, volume = libvirt_volume.node[each.key].name } }
        target = { dev = "vda", bus = "virtio" }
      },
      {
        device    = "cdrom"
        driver    = { name = "qemu", type = "raw" }
        source    = { file = { file = libvirt_cloudinit_disk.node[each.key].path } }
        target    = { dev = "sda", bus = "sata" }
        read_only = true
      },
    ]

    interfaces = [{
      mac    = { address = each.value.mac }
      source = { network = { network = libvirt_network.lab.name } }
      model  = { type = "virtio" }
    }]

    # The repo, shared in from the host. This is how Lab 3 moves signing
    # requests and certificates between machines.
    filesystems = [{
      driver      = { type = "virtiofs" }
      source      = { mount = { dir = local.repo_dir } }
      target      = { dir = var.share_tag }
      access_mode = "passthrough"
    }]

    # Required, and the least obvious requirement here. The provider adds no
    # video device of its own, and SeaBIOS will not boot a guest that has none:
    # the VM runs, consumes CPU, and produces no console output whatsoever.
    #
    # vram/primary/heads are set explicitly because leaving them null makes the
    # provider return values it did not plan, which fails the apply.
    videos = [{ model = { type = "vga", vram = 16384, primary = "yes", heads = 1 } }]

    serials  = [{ type = "pty" }]
    consoles = [{ type = "pty" }]
  }
}

# Written so `ssh ace-db` works from the repo directory once the Include line
# from Lab 2 is in ~/.ssh/config.
resource "local_file" "ssh_config" {
  filename        = "${path.module}/ssh_config"
  file_permission = "0644"

  content = join("\n", concat(
    ["# Generated by terraform. See Lab 2 for the one-line ~/.ssh/config include.", ""],
    flatten([
      for name, n in var.nodes : [
        "Host ${name}",
        "  HostName ${n.ip}",
        "  User ${var.guest_user}",
        "  IdentityFile ${pathexpand(replace(var.ssh_public_key_path, ".pub", ""))}",
        "  StrictHostKeyChecking no",
        "  UserKnownHostsFile /dev/null",
        "  LogLevel ERROR",
        "",
      ]
    ])
  ))
}
