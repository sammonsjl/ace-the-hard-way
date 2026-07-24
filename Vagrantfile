# ACE the Hard Way — lab environment
#
# Two VMs:
#   ace-control : the control plane (bare metal from source: postgres, redis, AWX, gateway)
#   ace-exec    : the execution plane (receptor + podman for EEs)
#
# Box: bento/rockylinux-9 — publishes libvirt and vmware images for both x86_64 and
# aarch64, so this one default works on Linux/KVM, Intel, and Apple Silicon.
# Providers: run end-to-end with libvirt (Linux, x86_64) and vmware_desktop (VMware
# Fusion, macOS). See Lab 1 for the matrix.

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

  config.vm.define "ace-control" do |node|
    node.vm.hostname = "ace-control"
    node.vm.network "private_network", ip: "192.168.56.10"

    # 8 GB: the UI build (npm) and pip wheel builds are RAM hungry
    node.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]  = "8192"
      v.vmx["numvcpus"] = "4"
      # Pin NIC PCI slots (bento box defaults) — silences the Vagrant VMX-allowlisting
      # warning and keeps networking stable when Vagrant stops managing these.
      v.vmx["ethernet0.pcislotnumber"] = "160"
      v.vmx["ethernet1.pcislotnumber"] = "224"
    end
    node.vm.provider "libvirt" do |v|
      v.memory = 8192
      v.cpus   = 4
    end
  end

  config.vm.define "ace-exec" do |node|
    node.vm.hostname = "ace-exec"
    node.vm.network "private_network", ip: "192.168.56.20"

    node.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]  = "4096"
      v.vmx["numvcpus"] = "2"
      v.vmx["ethernet0.pcislotnumber"] = "160"
      v.vmx["ethernet1.pcislotnumber"] = "224"
    end
    node.vm.provider "libvirt" do |v|
      v.memory = 4096
      v.cpus   = 2
    end
  end

  # Minimal common prep — everything else is done BY HAND in the labs.
  # (This is a hard-way tutorial: provisioning stays out of the way.)
  config.vm.provision "shell", inline: <<-SHELL
    dnf -y install vim curl jq git
  SHELL
end
