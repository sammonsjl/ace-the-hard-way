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
