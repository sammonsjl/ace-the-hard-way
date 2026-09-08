# ACE the Hard Way — lab environment
#
# Five VMs on a Proxmox VE node, mirroring the shape of a distributed RPM
# deployment:
#
#   ace-db          .40   PostgreSQL, alone on its own host
#   ace-gateway     .41   platform gateway + colocated Redis + envoy + the console
#   ace-controller  .42   AWX — a HYBRID node, so it also runs jobs in EE containers
#   ace-hub         .43   automation hub (galaxy_ng on pulpcore)
#   ace-eda         .44   Event-Driven Ansible
#
# A real deployment of this shape adds a sixth VM — a dedicated execution node —
# and keeps the controller control-only. We fold that role into the controller by
# making it a hybrid node, which is the one deliberate departure and saves a VM.
#
# Sizing and node addresses live in variables.tf.

locals {
  ssh_pubkey = trimspace(file(pathexpand(var.ssh_public_key_path)))

  # Rendered into /etc/hosts on every node, as quoted printf arguments.
  hosts_entries = join(" ", [
    for name, n in var.nodes : "'${n.ip} ${name}'"
  ])

  # The node that exports the shared directory, and its address.
  share_server_ip = var.nodes[var.share_server].ip

  # Every other node is an NFS client of it. One export line per client rather
  # than a whole-subnet export: the share carries certificate requests, and the
  # lab nodes are on your home LAN alongside everything else you own.
  share_clients = [
    for name, n in var.nodes : n.ip if name != var.share_server
  ]
}

# Downloaded to the Proxmox node once, then imported as the disk for all five
# VMs. `import` is a content type the datastore has to allow — see Lab 1.
resource "proxmox_download_file" "base" {
  node_name    = var.node_name
  content_type = "import"
  datastore_id = var.image_datastore_id
  url          = var.base_image_url
  file_name    = "ace-rocky9-base.qcow2"

  # The image is ~650 MB from dl.rockylinux.org and the default is two minutes.
  upload_timeout = 1800
}

# One cloud-init user-data document per node, uploaded to the snippets
# datastore. This is the reason the provider needs SSH to the Proxmox host:
# snippets are written as files on the node, not through the API.
#
# Proxmox can generate cloud-init itself from a username and a key, but that
# form can only make a user — it cannot install a package or write a file. The
# nodes need both, so the whole document is written here instead.
resource "proxmox_virtual_environment_file" "user_data" {
  for_each = var.nodes

  node_name    = var.node_name
  content_type = "snippets"
  datastore_id = var.snippet_datastore_id

  source_raw {
    file_name = "${each.key}-user-data.yaml"

    data = templatefile("${path.module}/cloud-init/user-data.yaml.tftpl", {
      hostname        = each.key
      guest_user      = var.guest_user
      ssh_pubkey      = local.ssh_pubkey
      share_mount     = var.share_mount
      hosts_entries   = local.hosts_entries
      is_share_server = each.key == var.share_server
      share_server_ip = local.share_server_ip
      share_clients   = local.share_clients
    })
  }
}

resource "proxmox_virtual_environment_vm" "node" {
  for_each = var.nodes

  node_name = var.node_name
  vm_id     = each.value.vm_id
  name      = each.key
  tags      = ["ace", "the-hard-way"]

  description = "ACE the Hard Way — ${each.key}"
  on_boot     = true

  machine       = "q35"
  scsi_hardware = "virtio-scsi-single"
  bios          = "seabios"

  # Deliberately off. With the agent enabled the provider waits for the guest to
  # answer before it considers the VM created — and the guest cannot answer
  # until cloud-init has installed qemu-guest-agent, which happens well after
  # boot. The addresses here are static and already known, so nothing is gained
  # by waiting for the agent to report them.
  agent {
    enabled = false
  }

  # Without the guest agent Proxmox has no way to ask the OS to shut down, so
  # tell it to pull the plug on destroy rather than wait for a graceful stop
  # that will never come.
  stop_on_destroy = true

  cpu {
    cores = each.value.vcpu
    type  = "host"
  }

  memory {
    dedicated = each.value.memory
  }

  network_device {
    bridge = var.bridge
  }

  disk {
    datastore_id = var.datastore_id
    interface    = "scsi0"
    iothread     = true
    discard      = "on"
    ssd          = true
    size         = var.disk_size_gb
    import_from  = proxmox_download_file.base.id
  }

  boot_order = ["scsi0"]

  operating_system {
    type = "l26"
  }

  initialization {
    datastore_id = var.datastore_id
    interface    = "ide2"

    # Static addressing means no DHCP server is answering these nodes, so the
    # resolvers have to be handed over explicitly or nothing resolves.
    dns {
      servers = var.dns_servers
    }

    ip_config {
      ipv4 {
        address = "${each.value.ip}/${var.netmask}"
        gateway = var.gateway_ip
      }
    }

    user_data_file_id = proxmox_virtual_environment_file.user_data[each.key].id
  }

  lifecycle {
    # The provider records the disk's post-import size, which does not always
    # round-trip identically to the requested value.
    ignore_changes = [disk[0].size]
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
