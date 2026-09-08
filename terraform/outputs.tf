output "nodes" {
  description = "Node name to address."
  value       = { for name, n in var.nodes : name => n.ip }
}

output "ssh_config_path" {
  description = "Include this from ~/.ssh/config to get `ssh ace-db` and friends."
  value       = abspath(local_file.ssh_config.filename)
}

output "share" {
  description = "Where the shared directory appears on every node, and which node exports it."
  value = {
    mount  = var.share_mount
    server = var.share_server
  }
}

output "base_image" {
  description = "The image the nodes were built from. Put `release` into fedora_release in terraform.tfvars to stop the lab rolling forward."
  value = {
    release   = local.fedora_release
    url       = local.base_image_url
    sha256    = local.base_image_checksum
    file_name = proxmox_download_file.base.file_name
    pinned    = var.fedora_release != null || var.base_image_url != null
  }
}
