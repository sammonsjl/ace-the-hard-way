# ACE the Hard Way — lab environment
#
# Two VMs:
#   ace-control : the control plane (bare metal from source: postgres, redis, AWX, gateway)
#   ace-exec    : the execution plane (receptor + podman for EEs)
#
# Box: bento/rockylinux-9 (publishes x86_64 and aarch64 — works on Intel and Apple Silicon)
# Providers: tested with vmware_desktop (VMware Fusion). virtualbox and libvirt blocks
# are provided untested — see Lab 1 for the provider/box matrix per platform.
# libvirt users: the bento box may lack a libvirt build — use VAGRANT_BOX=generic/rocky9.

Vagrant.configure("2") do |config|
  config.vm.box = ENV.fetch("VAGRANT_BOX", "bento/rockylinux-9")

  config.vm.define "ace-control" do |node|
    node.vm.hostname = "ace-control"
    node.vm.network "private_network", ip: "192.168.56.10"

    # 8 GB: the UI build (npm) and pip wheel builds are RAM hungry
    node.vm.provider "vmware_desktop" do |v|
      v.vmx["memsize"]  = "8192"
      v.vmx["numvcpus"] = "4"
    end
    node.vm.provider "virtualbox" do |v|
      v.memory = 8192
      v.cpus   = 4
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
    end
    node.vm.provider "virtualbox" do |v|
      v.memory = 4096
      v.cpus   = 2
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
