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

  # The same addresses again, as firewalld rich rules. Fedora Cloud runs
  # firewalld from first boot and its default zone permits ssh and little else,
  # so the export list above is not enough on its own — Lab 3 reaches for the
  # share, and the first firewall lab is Lab 5.
  share_firewall_rules = join(" ", [
    for ip in local.share_clients :
    "--add-rich-rule='rule family=ipv4 source address=${ip}/32 port port=2049 protocol=tcp accept'"
  ])
}

# Fedora's machine-readable release index, read on every plan. This is what
# makes the lab roll forward on its own: when the next Fedora ships, this is
# where it shows up. Skipped entirely when base_image_url is set, so a reader
# with no route to fedoraproject.org can still build the estate.
data "http" "fedora_releases" {
  count = var.base_image_url == null ? 1 : 0

  url                = var.fedora_releases_url
  request_headers    = { Accept = "application/json" }
  request_timeout_ms = 20000

  retry {
    attempts     = 3
    min_delay_ms = 2000
  }

  lifecycle {
    postcondition {
      condition     = self.status_code == 200
      error_message = "${var.fedora_releases_url} answered ${self.status_code}. Set fedora_release to pin a release, or base_image_url + base_image_checksum to bypass this lookup."
    }
  }
}

locals {
  # releases.json is a flat list of every artifact of every edition — a few
  # hundred entries across four architectures — so this has to be narrow. The
  # link regex carries most of the load and does it in one place:
  #
  #   /releases/<digits>/  a SHIPPED release. Prereleases live under
  #                        /releases/test/45_Beta/ and nightlies under
  #                        /development/45/, and neither matches. This is the
  #                        test that keeps a beta out during release week.
  #   Cloud/x86_64         not Server, Workstation, KDE, IoT, Silverblue, Labs,
  #                        Spins or Container; not aarch64, ppc64le, s390x.
  #   Generic              not Fedora-Cloud-Base-UEFI-UKI-*.qcow2, which ships
  #                        beside it under the same variant and will not boot
  #                        the seabios machine below; and not the AmazonEC2
  #                        .raw.xz, Azure .vhdfixed.xz, GCE .tar.gz or Vagrant
  #                        .box siblings, all of which are also variant Cloud.
  #   -<rel>-<build>       the build number. 44 alone is not a URL; 44-1.7 is.
  #
  # The version test is belt to that braces: a prerelease is "45_Beta" there,
  # and Rawhide is "Rawhide", so neither survives ^[0-9]+$.
  fedora_images = var.base_image_url != null ? [] : [
    for e in jsondecode(data.http.fedora_releases[0].response_body) : e
    if can(regex("^[0-9]+$", try(e.version, "")))
    && try(e.variant, "") == "Cloud"
    && try(e.subvariant, "") == "Cloud_Base"
    && try(e.arch, "") == "x86_64"
    && can(regex("/releases/[0-9]+/Cloud/x86_64/images/Fedora-Cloud-Base-Generic-[0-9]+-[0-9.]+\\.x86_64\\.qcow2$", try(e.link, "")))
    && can(regex("^[0-9a-f]{64}$", try(e.sha256, "")))
  ]

  # null means roll: take the highest release the index offers. A number pins,
  # and the exact URL, build number and checksum still come from the index.
  fedora_release = var.base_image_url != null ? null : coalesce(
    var.fedora_release,
    try(max([for e in local.fedora_images : tonumber(e.version)]...), 0),
  )

  fedora_image = try(
    [for e in local.fedora_images : e if tonumber(e.version) == local.fedora_release][0],
    null,
  )

  base_image_url      = var.base_image_url != null ? var.base_image_url : try(local.fedora_image.link, "")
  base_image_checksum = var.base_image_url != null ? var.base_image_checksum : try(local.fedora_image.sha256, "")

  # "44-1.7" — release AND build. This goes in the file name, so a new Fedora
  # arrives as a NEW file on the node rather than quietly replacing the one a
  # running estate was built from. See the VM lifecycle block below.
  base_image_build = try(
    regex("Generic-([0-9]+-[0-9.]+)\\.x86_64\\.qcow2$", local.base_image_url)[0],
    substr(sha256(local.base_image_url), 0, 8),
  )

  base_image_file_name = "ace-fedora-${local.base_image_build}.qcow2"
}

# Downloaded to the Proxmox node once, then imported as the disk for all five
# VMs. `import` is a content type the datastore has to allow — see Lab 1.
resource "proxmox_download_file" "base" {
  node_name    = var.node_name
  content_type = "import"
  datastore_id = var.image_datastore_id

  url = local.base_image_url

  # The release and build number are in the name — ace-fedora-44-1.7.qcow2 —
  # rather than a fixed "ace-fedora-base.qcow2". That is deliberate, and it is
  # the whole reason a new Fedora is safe to apply into a running lab. See the
  # note on the VM's lifecycle block.
  file_name = local.base_image_file_name

  # PVE verifies this itself, after the download and before the file is moved
  # into place. It matters more here than it would have with Rocky:
  # download.fedoraproject.org is a redirector, so the bytes arrive from
  # whichever community mirror it picks, and this is what makes that fine.
  checksum           = local.base_image_checksum
  checksum_algorithm = "sha256"

  # The URL is immutable — release and build are both in the path — so there is
  # nothing for the provider's per-refresh upstream size probe to catch.
  # Turning it off keeps `terraform plan` from reaching out to a mirror.
  overwrite = false

  # ~557 MB from a community mirror. The provider's default is 600 seconds,
  # which a slow mirror on a bad night genuinely exceeds.
  upload_timeout = 1800

  lifecycle {
    precondition {
      condition     = var.base_image_url == null || var.base_image_checksum != null
      error_message = "base_image_url needs base_image_checksum with it. An unverified image is not worth the escape hatch."
    }
    precondition {
      condition     = local.base_image_url != ""
      error_message = var.fedora_release == null ? "No stable Fedora Cloud Base Generic x86_64 qcow2 found in ${var.fedora_releases_url}. Set base_image_url + base_image_checksum to bypass it." : "Fedora ${var.fedora_release} has no Cloud Base Generic x86_64 qcow2 in ${var.fedora_releases_url} — it is probably end-of-life and gone from the index. Try a newer number, or null to roll to the latest."
    }
  }
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

      share_firewall_rules = local.share_firewall_rules
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

  # On. Fedora Cloud Base ships qemu-guest-agent in the image, so the guest can
  # answer as soon as Proxmox gives it something to answer on: the agent's
  # systemd unit is activated by the virtio-serial channel appearing, and that
  # channel only exists when this is enabled. Leave it off and the package sits
  # there installed and inert, with the service `inactive` and no
  # /dev/virtio-ports entry to trigger it.
  #
  # What it buys: the node reports each guest's IP in the Proxmox UI rather than
  # showing nothing, `qm shutdown` becomes a real ACPI-free graceful stop, and
  # snapshots can fsfreeze the filesystem instead of catching it mid-write.
  #
  # The cost is on create: the provider waits for the agent before it considers
  # a VM created. That is a real wait, but a short one here because the agent is
  # already in the image — it is not waiting on cloud-init to install anything.
  # The timeout is generous so a slow first boot does not fail an apply.
  agent {
    enabled = true
    timeout = "5m"
  }

  # Pull the plug on destroy rather than asking politely. With the agent enabled
  # a graceful shutdown would now work, so this is a choice rather than a
  # necessity: teardown is faster this way, and the disks are being deleted in
  # the same breath.
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
    #
    # import_from is here for a larger reason. It names the downloaded image,
    # and that name carries the Fedora release — so the day a new Fedora ships,
    # the image is replaced and this value changes on all five VMs at once. The
    # provider only reads import_from when it CREATES a VM ("changes after
    # creation are ignored"), so the update would be a no-op, but Terraform
    # would still print five VMs being modified, and a reader halfway through
    # Lab 6 should not have to work out whether that is safe.
    #
    # Ignoring it makes the plan say what is actually happening: one image is
    # replaced, five running machines are not touched. ignore_changes applies
    # only to objects that already exist, so a first apply — and any single VM
    # rebuilt later — still imports from the current image.
    #
    # user_data_file_id is here for the same reason and is the sharper of the
    # two. cloud-init user-data is a FIRST-BOOT input: editing the template
    # cannot change a machine that has already booted, but Terraform sees a new
    # snippet id and plans to REPLACE the VM to deliver it. Edit one line of the
    # template — the NFS rule below, say, which only affects the share server —
    # and the next apply proposes destroying ace-gateway, taking the internal
    # CA, envoy and the whole gateway build with it. The template still governs
    # what a freshly built estate gets; it just no longer rebuilds a standing
    # one. If you genuinely want new cloud-init applied, rebuild that VM
    # deliberately with `terraform taint`.
    ignore_changes = [
      disk[0].size,
      disk[0].import_from,
      initialization[0].user_data_file_id,
    ]
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
