terraform {
  required_version = ">= 1.5"

  required_providers {
    proxmox = {
      source  = "bpg/proxmox"
      version = "0.111.1"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "proxmox" {
  endpoint  = var.proxmox_endpoint
  api_token = var.proxmox_api_token
  insecure  = var.proxmox_insecure

  # Uploading a cloud-init snippet is a file copy onto the node, not an API
  # call, so the provider needs SSH to the Proxmox host in addition to the API
  # token. Everything else here is API-only.
  ssh {
    agent    = var.proxmox_ssh_agent
    username = var.proxmox_ssh_username
    password = var.proxmox_ssh_password
  }
}
