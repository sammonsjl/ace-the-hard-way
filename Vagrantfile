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
# MEMORY. A production build of this topology asks for 16 GB *per VM*. This is the
# same shape shrunk to fit 16 GB *in total*, so every number below is a lab
# compromise rather than a recommendation:
#
#   ace-db           1024      postgres alone needs very little
#   ace-gateway      5120      the biggest, because the console's npm build is
#                              the single most memory-hungry step in the tutorial
#   ace-controller   3584      tight; it runs AWX and EE containers
#   ace-hub          2560
#   ace-eda          2048
#                   ------
#                   14336      leaves ~1.5 GB for the host
#
# Box: bento/rockylinux-9 — publishes libvirt and vmware images for both x86_64 and
# aarch64, so this one default works on Linux/KVM, Intel, and Apple Silicon.
# Providers: run end-to-end with libvirt (Linux, x86_64) and vmware_desktop (VMware
# Fusion, macOS). See Lab 1 for the matrix.

NODES = [
  { name: "ace-db",         ip: "192.168.56.10", mem: 1024, cpus: 1 },
  { name: "ace-gateway",    ip: "192.168.56.11", mem: 5120, cpus: 2 },
  { name: "ace-controller", ip: "192.168.56.12", mem: 3584, cpus: 2 },
  { name: "ace-hub",        ip: "192.168.56.13", mem: 2560, cpus: 2 },
  { name: "ace-eda",        ip: "192.168.56.14", mem: 2048, cpus: 2 },
].freeze

Vagrant.configure("2") do |config|
  config.vm.box = ENV.fetch("VAGRANT_BOX", "bento/rockylinux-9")

  # The repo is shared into every VM at /vagrant (two-way sync).
  # Handy for reading the labs from inside the VM — and for editing them
  # the moment reality disagrees with the docs.
  #
  # NFSv4 over TCP: the vagrant-libvirt default (vers=3,udp) is rejected by
  # modern Linux guests — Rocky 9 errors with "an incorrect mount option was
  # specified", since NFS-over-UDP is dropped on current kernels. v4/tcp also
  # needs no rpcbind/mountd. (vmware_desktop ignores these nfs_* opts.)
  config.vm.synced_folder ".", "/vagrant", type: "nfs", nfs_version: 4, nfs_udp: false

  NODES.each do |n|
    config.vm.define n[:name] do |node|
      node.vm.hostname = n[:name]
      node.vm.network "private_network", ip: n[:ip]

      node.vm.provider "vmware_desktop" do |v|
        v.vmx["memsize"]  = n[:mem].to_s
        v.vmx["numvcpus"] = n[:cpus].to_s
        # Pin NIC PCI slots (bento box defaults) — silences the Vagrant VMX-allowlisting
        # warning and keeps networking stable when Vagrant stops managing these.
        v.vmx["ethernet0.pcislotnumber"] = "160"
        v.vmx["ethernet1.pcislotnumber"] = "224"
      end
      node.vm.provider "libvirt" do |v|
        v.memory = n[:mem]
        v.cpus   = n[:cpus]
      end
    end
  end

  # Minimal common prep — everything else is done BY HAND in the labs.
  # (This is a hard-way tutorial: provisioning stays out of the way.)
  #
  # /etc/hosts for all five nodes goes in here rather than in a lab, because
  # every node needs every other node's name from Lab 3 onward (certificate SANs,
  # database connection strings, the receptor mesh) and hand-editing five files
  # teaches nothing. The box image's own 127.0.1.1 self-mapping is removed first —
  # left in place it wins, and a node signs a certificate for a loopback address.
  config.vm.provision "shell", inline: <<-SHELL
    dnf -y install vim curl jq git
    sed -i '/127\\.0\\.1\\.1/d' /etc/hosts
    grep -q 'ace-gateway' /etc/hosts || cat >> /etc/hosts <<'EOF'
192.168.56.10 ace-db
192.168.56.11 ace-gateway
192.168.56.12 ace-controller
192.168.56.13 ace-hub
192.168.56.14 ace-eda
EOF
  SHELL
end
