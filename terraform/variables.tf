variable "libvirt_uri" {
  description = "libvirt connection. qemu:///system runs the VMs as the system libvirt daemon, which is what the storage pool and NAT networking below assume."
  type        = string
  default     = "qemu:///system"
}

variable "pool" {
  description = "libvirt storage pool for the base image and the per-VM overlays."
  type        = string
  default     = "default"
}

variable "network_name" {
  description = "Name of the libvirt network this lab creates."
  type        = string
  default     = "ace-lab"
}

variable "network_cidr" {
  description = "The lab subnet. Every node address below lives here, and the labs, certificates and /etc/hosts all assume it."
  type        = string
  default     = "192.168.56.0/24"
}

variable "gateway_ip" {
  description = "Host-side address of the lab network; also the guests' default route and DNS."
  type        = string
  default     = "192.168.56.1"
}

variable "base_image_url" {
  description = <<-EOT
    Rocky 9 GenericCloud qcow2. Downloaded once and used as the backing store
    for all five overlays. Served straight from dl.rockylinux.org, so there is
    no third-party image registry on the critical path.
  EOT
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "disk_size" {
  description = "Per-VM virtual disk size in bytes. The image is 10 GiB; cloud-init's growpart expands the root partition to fill whatever is set here."
  type        = number
  default     = 64424509440 # 60 GiB
}

variable "ssh_public_key_path" {
  description = "Public key injected into every node. Keep the private key on LOCAL disk — ssh refuses a key it does not believe you own, which bites if the repo lives on a NAS with a different uid."
  type        = string
  default     = "~/.ssh/ace_lab_ed25519.pub"
}

variable "guest_user" {
  description = "Login user created on every node. This is the Rocky cloud image's own default user; it gets passwordless sudo."
  type        = string
  default     = "rocky"
}

variable "share_mount" {
  description = "Where the repo is mounted inside every VM. The labs hand certificates between nodes through here."
  type        = string
  default     = "/srv/ace"
}

variable "share_tag" {
  description = "virtiofs mount tag connecting the guest mount to the host directory."
  type        = string
  default     = "acefs"
}

variable "nodes" {
  description = <<-EOT
    The five machines, mirroring the shape of a distributed RPM deployment.

    MEMORY. A production build of this topology asks for 16 GB *per VM*. This is
    the same shape shrunk to fit 16 GB *in total*, so every number here is a lab
    compromise rather than a recommendation. Total: 14336 MB, leaving ~1.5 GB for
    the host.
  EOT
  type = map(object({
    ip     = string
    mac    = string
    memory = number
    vcpu   = number
  }))
  default = {
    # postgres alone needs very little
    ace-db = { ip = "192.168.56.10", mac = "52:54:00:ac:e0:10", memory = 1024, vcpu = 1 }
    # the biggest, because the console's npm build is the single most
    # memory-hungry step in the tutorial
    ace-gateway = { ip = "192.168.56.11", mac = "52:54:00:ac:e0:11", memory = 5120, vcpu = 2 }
    # tight; it runs AWX and EE containers
    ace-controller = { ip = "192.168.56.12", mac = "52:54:00:ac:e0:12", memory = 3584, vcpu = 2 }
    ace-hub        = { ip = "192.168.56.13", mac = "52:54:00:ac:e0:13", memory = 2560, vcpu = 2 }
    ace-eda        = { ip = "192.168.56.14", mac = "52:54:00:ac:e0:14", memory = 2048, vcpu = 2 }
  }
}
