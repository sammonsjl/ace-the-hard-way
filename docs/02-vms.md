# Lab 2 — The five VMs

## What you will have at the end

Five Rocky Linux 9 VMs that can see and name each other, and all pass the preflight checks.
Nothing component-specific — that starts in Lab 4.

## The topology, and why it has this shape

A real deployment of this platform is not one machine. Its smallest tested distributed shape puts
each component on its own host:

| VM                 | Address       | Runs                                                            |
| ------------------ | ------------- | --------------------------------------------------------------- |
| **ace-db**         | 192.168.1.40 | PostgreSQL, and nothing else                                    |
| **ace-gateway**    | 192.168.1.41 | the platform gateway, Redis, envoy, and the console             |
| **ace-controller** | 192.168.1.42 | the automation controller — and, as a **hybrid** node, jobs too |
| **ace-hub**        | 192.168.1.43 | automation hub                                                  |
| **ace-eda**        | 192.168.1.44 | Event-Driven Ansible                                            |

The real shape has a **sixth** VM: a dedicated execution node, with the controller kept
control-only. We fold that role into the controller by making it a **hybrid** node — one that
both schedules work and runs it. That is the single deliberate departure in this tutorial, and it
is worth understanding rather than skipping past:

- A **control** node schedules jobs and hands them to receptor. It never runs a playbook itself,
  except for control-plane work like project syncs.
- An **execution** node runs jobs and nothing else.
- A **hybrid** node does both.

Splitting them is what lets you scale execution independently of the control plane, and it is why
production deployments do it. Combining them costs you that, saves a VM, and changes nothing else
about how execution works — the controller still submits signed work to receptor, receptor still
spawns `ansible-runner`, and jobs still run in containers. The only difference is that the
receptor receiving the work is the same one that submitted it — one node, no peer, and no network
hop between them.

## Why each component gets its own machine

It is tempting to read this as five times the work. It isn't — it is the *same* work with the
seams made visible, and the seams are the interesting part:

- **Every connection becomes real.** With everything on one box, "the controller talks to the
  database" is a unix socket and a shrug. Here it is a hostname, a port, a firewall rule, and a
  certificate whose SAN has to match. When something breaks, you find out which of those it was.
- **You cannot accidentally share state.** One machine makes it very easy to have the controller
  quietly depend on a file the hub created. Five machines make that impossible.
- **The gateway's job stops being abstract.** Four services on four hosts, one URL, one login.

## Memory and CPU

The numbers in `terraform/variables.tf` are sized for a Proxmox node with 32 GB:

```
                 MB    vCPU
ace-db          2048     2    postgres alone needs very little
ace-gateway     8192     4    the console's npm build is the hungriest step in the tutorial
ace-controller  6144     4    runs AWX, and as a hybrid node the EE containers too
ace-hub         4096     2
ace-eda         3072     2
               -----    --
               23552    14
```

Nothing in the tutorial depends on these exact numbers. On a smaller host, the laptop-scale set
that also works is `1024 / 5120 / 3584 / 2560 / 2048` — 14 GB in total, at the cost of the console
build in [Lab 5](05-gateway.md) leaning on swap, which that lab sets up. Those numbers are kept in
the `nodes` variable's description so you don't have to re-derive them.

The 14 vCPU deliberately overcommits an 8-core host. The nodes are idle most of the time and the two
long compiles are on different machines, so the overcommit buys parallelism during the builds and
costs nothing at rest.

## Bring them up

From the `terraform/` directory:

```bash
cd terraform
terraform init
terraform apply
```

That takes a while on first run. In order, it: downloads the Rocky 9 cloud image once (~650 MB) —
onto the *Proxmox node*, not your workstation, so the speed that matters is the node's link to
`dl.rockylinux.org`; uploads five cloud-init documents to the snippets datastore; then creates and
boots five VMs, importing that one image as each VM's disk.

Expect a minute for the download and around twenty seconds for the VMs.

Terraform prints the addresses when it finishes. To see them again:

```bash
terraform output
```

### Reaching them

Terraform writes an `ssh_config` next to the configuration. Include it once and every node is
reachable by name:

```bash
printf '\nInclude %s\n' "$(terraform output -raw ssh_config_path)" >> ~/.ssh/config
```

The leading newline matters: a plain `echo ... >> ~/.ssh/config` lands on the same line as
whatever your last line already was if that file doesn't end in a newline — you get a merged,
unparsable line (`SetEnv TERM=xterm-256colorInclude /path/...`) instead of a new one.

> **Repo on a NAS/NFS mount?** `Include` refuses a config file it doesn't consider owned by you
> or root. NFS commonly reports every file under the *server's* uid/gid, not your local one, so
> `terraform/ssh_config` can fail ownership even though you created it. If `ssh` errors with `Bad
> owner or permissions`, copy the file to somewhere local instead of including it in place:
> ```bash
> cp terraform/ssh_config ~/.ssh/ace-lab-ssh-config
> printf '\nInclude %s\n' ~/.ssh/ace-lab-ssh-config >> ~/.ssh/config
> ```
> Re-run the `cp` any time Terraform regenerates `ssh_config` (a new `apply` that changes nodes).

Order matters in `ssh_config` — if your `~/.ssh/config` already has a catch-all `Host *` block,
put the `Include` line **below** it, not above. `Host *` here only sets connection-wide options
(`IdentityAgent`, `ServerAliveInterval`, and the like), never `HostName`/`User`/`IdentityFile`, so
first-match-wins never causes a conflict — but on at least OpenSSH 10.5p1, an `Include` placed
*before* a `Host *` block gets parsed without ever applying its `Host` matches (visible as
`(parse only)` in `ssh -vvv`), so nothing in the included file takes effect at all. Putting
`Include` after `Host *` avoids this outright.

Then, from anywhere:

```bash
ssh ace-controller
```

That is the command used throughout the rest of the tutorial. If you would rather not touch
`~/.ssh/config`, `ssh -F terraform/ssh_config ace-controller` does the same thing.

### What cloud-init did

Beyond booting, each VM does only three things: it installs `vim curl jq git nfs-utils`, it writes
`/etc/hosts`, and it wires up the shared directory described below.

The `/etc/hosts` part is not laziness. Every node needs every other node's name from
[Lab 3](03-internal-ca.md) onward — certificate SANs, database connection strings, the gateway's
service registry — and hand-editing five files five times teaches nothing. It also deletes the cloud
image's own `127.0.1.1` self-mapping first, which matters more than it looks:

```bash
ssh ace-controller 'getent ahostsv4 ace-db ace-gateway | head -2; grep -c 127.0.1.1 /etc/hosts'
```

> **Why the `127.0.1.1` line has to go.** The cloud image maps its own hostname to a loopback
> address. Leave it and `ace-gateway` resolves to `127.0.1.1` *on the gateway itself* — so the
> certificate you sign in Lab 3 carries `IP:127.0.1.1`, and every other machine's TLS connection
> fails a hostname check for reasons that point at the certificate rather than at `/etc/hosts`.
>
> Also note `getent ahostsv4`, not `getent hosts`. On a multi-homed machine the latter returns a
> link-local `fe80::` address first, and an `fe80::` in a certificate SAN is worse than no SAN.

Addresses are set by Proxmox's cloud-init drive rather than by DHCP, so each node comes up on the
address the labs expect whether or not anything on your network is handing out leases. Static
addressing also means no DHCP server is supplying resolvers, which is why `dns_servers` is a
variable — get it wrong and the symptom is a VM that boots fine and cannot resolve anything.

> **Give cloud-init time to finish.** `terraform apply` returns when the VMs are *defined and
> booting*, not when they are ready — first boot still has to grow the root filesystem, create your
> user, and install packages. Roughly two minutes. If `ssh` is refused, or refuses your key, that is
> almost always cloud-init still working rather than anything broken. To wait properly:
>
> ```bash
> for vm in ace-db ace-gateway ace-controller ace-hub ace-eda; do
>   printf "%-16s " "$vm"; ssh "$vm" 'sudo cloud-init status --wait'
> done
> ```
>
> All five should report `status: done`.

### The shared directory

Every node has **`/srv/ace`**. On `ace-gateway` it is a real directory; on the other four it is an
NFS mount of the gateway's copy. It exists for exactly one job: it is the courier that carries
certificate requests and signed certificates between machines in [Lab 3](03-internal-ca.md).

The gateway holds it because the gateway holds the CA — the courier lives where the signing does,
so a certificate is only ever one hop from the key that signs it.

```bash
ssh ace-gateway 'sudo touch /srv/ace/hello'
ssh ace-db      'sudo ls -l /srv/ace/'
ssh ace-gateway 'sudo rm /srv/ace/hello'
```

If `ace-db` sees `hello`, the courier works. If it sees an empty directory, it is writing to its own
local `/srv/ace` instead of the gateway's — see below.

Three things about it are worth knowing, because each one is a way it can look fine and not be:

- **Writes need `sudo`.** The directory is root-owned, and both certificate scripts in
  [Lab 3](03-internal-ca.md) live in `/usr/local/sbin` and run under `sudo` anyway. The export is
  `no_root_squash` for that reason: the default would map those root writes to `nobody` and refuse
  them.
- **It mounts on demand, not at boot.** The fstab entry uses `x-systemd.automount`, so the mount is
  attempted the first time something touches the directory — Lab 3, long after the estate is up —
  rather than at boot, when the gateway may not be exporting yet. This is what makes the boot order
  of the five VMs irrelevant.
- **An unmounted share is silent.** `/srv/ace` exists on every node whether or not the NFS mount is
  live, so a broken mount does not produce an error — it produces an empty directory, and a
  certificate written on one machine that simply isn't there on the other. `findmnt` is the check
  that actually answers the question:

  ```bash
  for vm in ace-db ace-controller ace-hub ace-eda; do
    printf "%-16s " "$vm"; ssh "$vm" 'sudo ls /srv/ace >/dev/null; findmnt -no SOURCE,FSTYPE /srv/ace || echo "NOT MOUNTED"'
  done
  ```

  Each should report `192.168.1.41:/srv/ace nfs4`. The `ls` first is deliberate — it pokes the
  automount into mounting, which `findmnt` alone would not do.

> **Why not share the repo itself?** The libvirt build of this lab mounted the repo into each VM
> over virtiofs, which is neat when the hypervisor is the machine you are sitting at. Proxmox is
> not: the repo is on your workstation and the VMs are somewhere else entirely. Since nothing in the
> tutorial ever reads a repo file from inside a VM — every source checkout is a `git clone` over the
> network — the share only ever needed to move certificates between the five nodes, and NFS between
> the nodes themselves does that without involving your workstation at all.

## Bring them current

A cloud image is a snapshot of some Tuesday months ago, so all five VMs boot well behind their own
repos — several hundred packages, including a kernel. Update the estate now, in one loop:

```bash
for vm in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  echo "───── $vm"
  ssh "$vm" 'sudo dnf -y update'
done
```

Expect this to be the slowest step in the lab and to print a great deal — several hundred packages
per VM, downloaded five times over. Then reboot, because that set almost always includes a kernel
and you are still running the old one:

```bash
for vm in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  ssh "$vm" 'sudo systemctl reboot' || true
done

sleep 45

for vm in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  printf "%-16s " "$vm"
  ssh "$vm" 'uname -r'
done
```

All five should report the same, newer kernel. If one still shows the old version, that VM didn't
come back cleanly — reboot it on its own before continuing, either from the Proxmox UI or from a
root shell on the node:

```bash
qm reboot 140      # ace-db; .41 is 141, and so on
```

The VM IDs are `140`–`144`, chosen to match the last octet of each node's address.

Do this **here**, not later. Three of the things in that backlog are load-bearing for what follows:
`ca-certificates` and `openssl` decide whether the private CA in [Lab 3](03-internal-ca.md)
behaves, `glibc` and `python3` decide whether the wheels you compile from Lab 5 onward match the
interpreter that loads them, and the kernel decides whether podman's rootless plumbing works in
[Lab 7](07-execution.md). Discovering any of those mid-build means unpicking a component's install
to find out that the machine, not the component, was wrong.

## What this lab does NOT do

No service users, no application directories, no packages beyond `vim curl jq git`.

Each component creates its own user and its own filesystem layout in its own lab, on its own
machine — the gateway in [Lab 5](05-gateway.md), the controller in [Lab 6](06-controller.md), hub
in [Lab 8](08-hub.md), EDA in [Lab 9](09-eda.md). That is not tidiness for its own sake: an `awx`
user on the hub node would be a lie about what runs there, and a reader who stops after Lab 5
should have a gateway machine with nothing else pre-seeded on it.

What this lab leaves you is five interchangeable Rocky machines that can find each other. Everything
that makes a machine *the controller* or *the hub* happens in that component's lab.

## Preflight checks

Each of these is a precondition the rest of the tutorial silently assumes, and each has to hold on
**all five** machines. Rather than SSH into each box in turn, run the whole set from your workstation:

```bash
PREFLIGHT=$(cat <<'EOF'
systemctl is-active --quiet chronyd \
  && echo "OK   chronyd active" || echo "FAIL chronyd not active"
ref=$(chronyc tracking 2>/dev/null | awk -F'[ ]*:[ ]*' '/Reference ID/{print $2}')
case "$ref" in
  ""|*00000000*) echo "FAIL clock not synchronised" ;;
  *)             echo "OK   clock synced to $ref" ;;
esac

[ "$(locale 2>/dev/null | grep -c 'UTF-8')" -gt 0 ] \
  && echo "OK   UTF-8 locale" || echo "FAIL locale is not UTF-8"

hn=$(hostnamectl hostname)
case "$hn" in
  ace-*) echo "OK   hostname $hn" ;;
  *)     echo "FAIL hostname is '$hn', expected an ace-* name" ;;
esac

bad=""
for d in /var /tmp /var/tmp; do
  findmnt -no OPTIONS --target "$d" | grep -q noexec && bad="$bad $d"
done
[ -z "$bad" ] && echo "OK   /var /tmp /var/tmp all exec" \
              || echo "FAIL noexec on:$bad"

down=""
for h in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  ping -c1 -W2 "$h" >/dev/null 2>&1 || down="$down $h"
done
[ -z "$down" ] && echo "OK   reaches all five nodes by name" \
               || echo "FAIL cannot reach:$down"
EOF
)

for vm in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  echo "───── $vm"
  ssh "$vm" "$PREFLIGHT"
done
```

The quoted heredoc (`<<'EOF'`) matters: it stops your workstation's shell expanding `$d`, `$h` and the
`$(...)` calls before they ever reach a VM. The script travels across as literal text and is
evaluated by the remote shell, which is where every one of those variables belongs.

Six `OK` lines per machine, thirty in all, and the estate is ready:

```
───── ace-db
OK   chronyd active
OK   clock synced to 40832FB2 (64-131-47-178.metronet.net)
OK   UTF-8 locale
OK   hostname ace-db
OK   /var /tmp /var/tmp all exec
OK   reaches all five nodes by name
───── ace-gateway
...
```

Any `FAIL` = fix it now; every one of these produces a confusing failure several labs later if
ignored. Note that check 5 includes each node pinging *itself*, which is deliberate — a box that
can't resolve its own name will hand you a certificate mismatch in [Lab 3](03-internal-ca.md). To
re-check a single machine after a fix, drop the loop and run `ssh ace-db "$PREFLIGHT"`
directly.

Next: [The internal CA](03-internal-ca.md)
