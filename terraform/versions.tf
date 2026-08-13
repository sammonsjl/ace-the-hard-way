terraform {
  required_version = ">= 1.5"

  required_providers {
    # Pinned deliberately. 0.9.x is a full rewrite on the Terraform Plugin
    # Framework; the 0.8.x line is a different schema entirely and its
    # `filesystem` block only speaks 9p, which Rocky 9 cannot mount.
    libvirt = {
      source  = "dmacvicar/libvirt"
      version = "0.9.8"
    }
    local = {
      source  = "hashicorp/local"
      version = "~> 2.5"
    }
  }
}

provider "libvirt" {
  uri = var.libvirt_uri
}
