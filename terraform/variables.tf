variable "proxmox_endpoint" {
  description = "Proxmox VE API endpoint, including scheme and port."
  type        = string
  default     = "https://192.168.1.2:8006"
}

variable "proxmox_api_token" {
  description = <<-EOT
    Proxmox API token, in the form `user@realm!tokenid=uuid`. Create one with

      pveum user token add root@pam ace --privsep 0

    Keep it out of the repo: set it as TF_VAR_proxmox_api_token, or put it in
    terraform.tfvars, which .gitignore already excludes.
  EOT
  type        = string
  sensitive   = true
}

variable "proxmox_insecure" {
  description = "Skip TLS verification of the Proxmox API certificate. A stock Proxmox install has a self-signed certificate, so this starts true."
  type        = bool
  default     = true
}

variable "proxmox_ssh_username" {
  description = "SSH user on the Proxmox node. Needs write access to the snippets datastore, so in practice this is root."
  type        = string
  default     = "root"
}

variable "proxmox_ssh_password" {
  description = "Password for proxmox_ssh_username. Leave empty and set proxmox_ssh_agent = true to use an SSH agent key instead."
  type        = string
  sensitive   = true
  default     = ""
}

variable "proxmox_ssh_agent" {
  description = "Authenticate the provider's SSH connection through your SSH agent rather than proxmox_ssh_password."
  type        = bool
  default     = false
}

variable "node_name" {
  description = "Proxmox node the VMs are created on."
  type        = string
  default     = "lud"
}

variable "datastore_id" {
  description = "Datastore for the VM disks and cloud-init drives. Must accept the `images` content type."
  type        = string
  default     = "local-lvm"
}

variable "image_datastore_id" {
  description = "Datastore holding the downloaded cloud image. Must accept the `import` content type."
  type        = string
  default     = "local"
}

variable "snippet_datastore_id" {
  description = "Datastore holding the generated cloud-init user-data. Must accept the `snippets` content type — on a stock install that is `local`, but the type is off by default and has to be ticked on in Datacenter → Storage."
  type        = string
  default     = "local"
}

variable "bridge" {
  description = "Proxmox bridge the VMs attach to. vmbr0 is the stock LAN-facing bridge, which is what puts the nodes on your home network."
  type        = string
  default     = "vmbr0"
}

variable "gateway_ip" {
  description = "Default route for the VMs — your LAN's router."
  type        = string
  default     = "192.168.1.1"
}

variable "netmask" {
  description = "Prefix length for the node addresses, matching your LAN."
  type        = number
  default     = 24
}

variable "dns_servers" {
  description = "Resolvers handed to the guests. Static addressing means no DHCP is answering, so these have to be set or nothing resolves."
  type        = list(string)
  default     = ["192.168.1.1"]
}

variable "base_image_url" {
  description = <<-EOT
    Rocky 9 GenericCloud qcow2. Downloaded to the Proxmox node once and imported
    as the disk for all five VMs. Served straight from dl.rockylinux.org, so
    there is no third-party image registry on the critical path.
  EOT
  type        = string
  default     = "https://dl.rockylinux.org/pub/rocky/9/images/x86_64/Rocky-9-GenericCloud-Base.latest.x86_64.qcow2"
}

variable "disk_size_gb" {
  description = "Per-VM disk size in GiB. The image is 10 GiB; cloud-init's growpart expands the root filesystem to fill this on first boot."
  type        = number
  default     = 60
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
  description = "Where the shared directory appears on every node. The labs hand certificates between machines through here."
  type        = string
  default     = "/srv/ace"
}

variable "share_server" {
  description = "Which node exports share_mount over NFS. The gateway is the natural choice: it already holds the CA, so the courier lives where the signing does."
  type        = string
  default     = "ace-gateway"
}

variable "nodes" {
  description = <<-EOT
    The five machines, mirroring the shape of a distributed RPM deployment.

    MEMORY. These are sized for a Proxmox host with 32 GB, and total 23 GB —
    generous enough that no step in the tutorial has to lean on swap. On a
    smaller host, the laptop-scale numbers that also work are 1024 / 5120 /
    3584 / 2560 / 2048, totalling 14 GB.

    CPU. 14 vCPU across five VMs deliberately overcommits an 8-core host. The
    nodes are idle most of the time and the two long compiles are on different
    machines, so the overcommit buys parallelism during the builds without
    costing anything at rest.
  EOT
  type = map(object({
    vm_id  = number
    ip     = string
    memory = number
    vcpu   = number
  }))
  default = {
    # postgres alone needs very little
    ace-db = { vm_id = 140, ip = "192.168.1.40", memory = 2048, vcpu = 2 }
    # the biggest, because the console's npm build is the single most
    # memory-hungry step in the tutorial — and it also exports the share
    ace-gateway = { vm_id = 141, ip = "192.168.1.41", memory = 8192, vcpu = 4 }
    # runs AWX and, as a hybrid node, the EE containers that execute jobs
    ace-controller = { vm_id = 142, ip = "192.168.1.42", memory = 6144, vcpu = 4 }
    ace-hub        = { vm_id = 143, ip = "192.168.1.43", memory = 4096, vcpu = 2 }
    ace-eda        = { vm_id = 144, ip = "192.168.1.44", memory = 3072, vcpu = 2 }
  }
}
