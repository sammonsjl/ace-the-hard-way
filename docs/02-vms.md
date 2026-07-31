# Lab 2 — Provisioning the VMs

## What you'll have at the end

Two Rocky Linux 9 VMs that can see each other, both passing the preflight checks, with the `awx` service user on both and the full filesystem contract laid down on the control node.

## Bring them up

```bash
vagrant up
vagrant status    # both running
```

| VM | IP | Role |
|---|---|---|
| ace-control | 192.168.56.10 | Control plane (bare metal) |
| ace-exec | 192.168.56.20 | Execution plane (receptor + EEs) |

## Prep the control node

```bash
vagrant ssh ace-control
```

Create the dedicated `awx` service user everything will run under (no service runs as root). Home is `/var/lib/awx`, which is where AWX expects to find its projects, job output, and venv; it gets a real shell because init commands run as this user (`sudo -u awx awx-manage ...`):

```bash
sudo useradd --system --home-dir /var/lib/awx --create-home --shell /bin/bash awx
```

Build the directory tree from the filesystem contract below:

```bash
# home layout: projects, job output, static files, and the venv's future home
sudo install -d -o awx -g awx -m 0755 /var/lib/awx
sudo install -d -o awx -g awx -m 0700 /var/lib/awx/.ssh
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/projects
sudo install -d -o awx -g awx -m 0750 /var/lib/awx/job_status
sudo install -d -o awx -g awx -m 0755 /var/lib/awx/venv
sudo install -d -o root -g awx -m 0755 /var/lib/awx/public/static

# config root (settings.py, conf.d fragments, SECRET_KEY, certs)
sudo install -d -o root -g awx -m 0755 /etc/tower
sudo install -d -o root -g awx -m 0750 /etc/tower/conf.d

# logs: app logs (awx-owned) and supervisor's per-process logs
sudo install -d -o awx  -g awx  -m 0750 /var/log/tower
sudo install -d -o root -g root -m 0755 /var/log/supervisor

# the home dir must be 0755 — nginx must traverse it to serve
# /var/lib/awx/public later. useradd created it 0700; fix that now or Lab 12
# ends in "stat() failed (13: Permission denied)" on every static file.
sudo chmod 0755 /var/lib/awx
```

`/var/run/tower` — where the uwsgi and daphne sockets will live — is deliberately *not* created
here. It has to be owned by `nginx`, and that user doesn't exist yet.
[Lab 11](11-awx-services.md) creates it, with the tmpfiles.d entry that rebuilds it on every boot.

## Make the node names resolve (both VMs)

Every later lab addresses these boxes by name: certificate SANs, the receptor mesh, nginx
`server_name`, the gateway's own self-calls. Right now they don't resolve to anything useful —
the box image maps its own hostname to `127.0.1.1`, and the only other address either VM knows
about is the hypervisor's management network, not the lab network.

Two `/etc/hosts` lines stand in for DNS. Run this on **both** VMs:

```bash
# drop the box's self-mapping, which would otherwise win
sudo sed -i '/127\.0\.1\.1/d' /etc/hosts

sudo tee -a /etc/hosts >/dev/null <<'EOF'
192.168.56.10 ace-control
192.168.56.20 ace-exec
EOF

getent ahostsv4 ace-control | head -1    # want: 192.168.56.10
getent ahostsv4 ace-exec    | head -1    # want: 192.168.56.20
```

> **`ahostsv4`, not `hosts`.** `getent hosts` returns whatever the resolver offers first, which on
> a multi-homed box with IPv6 is often a link-local `fe80::` address. [Lab 3](03-internal-ca.md)'s
> certificate signing reads this, and an `fe80::` address in a SAN is worse than no SAN at all.
>
> Deleting the `127.0.1.1` line matters just as much. Leave it and `ace-control` resolves to a
> loopback address on the control node itself — so the certificate you sign in Lab 3 carries
> `IP:127.0.1.1`, and every other machine's connection fails the hostname check.

Update the base system:

```bash
sudo dnf -y update
cat /etc/rocky-release
```

**Verify the node**, then reboot as the last step (applies any kernel update):

```bash
id awx                              # service user exists
sudo -u awx bash -c 'echo $HOME'    # /var/lib/awx
ping -c1 192.168.56.20              # execution plane reachable
# ...plus the Preflight checks (section below)
sudo reboot                         # ssh session drops; that's expected
```

## Prep the execution plane node

`ace-exec` needs exactly one thing today — the same service user, because receptor runs as `awx` on execution nodes too. Everything else (receptor, podman, TLS) is Lab 14's job:

```bash
vagrant ssh ace-exec
sudo useradd --system --home-dir /var/lib/awx --create-home --shell /bin/bash awx
sudo dnf -y update
```

Verify, then reboot as the last step:

```bash
id awx                              # service user exists
ping -c1 192.168.56.10              # control plane reachable the other way
# ...plus the Preflight checks (section below)
sudo reboot
```

Both VMs verified and rebooted = Lab 2 done.

## The filesystem contract

One user, five directories. Lay it down once here and every later lab has a home for its files:

| Path | Owner | Purpose |
|---|---|---|
| `/var/lib/awx` | awx:awx 0755 | home: venv (`venv/awx/`), `projects/`, `job_status/`, `public/static/` |
| `/etc/tower` | **root**:awx 0755 | `settings.py`, `conf.d/*.py` (0750), `SECRET_KEY` (0400), TLS cert/key |
| `/var/run/tower` | nginx:nginx 2775 | uwsgi + daphne sockets (Lab 11 — needs tmpfiles.d, they vanish on reboot) |
| `/var/log/tower` | awx:awx (0750) | application logs |
| `/var/log/supervisor` | root | per-process supervisor logs |

(Commands for all of this are in "Prep the control node" above.)

## Preflight checks

Each of these is a precondition the rest of the tutorial silently assumes. Run them all on BOTH VMs:

```bash
# 1. Time sync — clock skew breaks TLS handshakes and job timestamps
systemctl is-active chronyd        # want: active   (if not: sudo dnf -y install chrony && sudo systemctl enable --now chronyd)
chronyc tracking | head -3         # want: a real reference ID, small offset

# 2. UTF-8 locale — non-UTF-8 breaks Django and postgres init
locale | grep -c 'UTF-8'           # want: > 0, no errors printed

# 3. Enough RAM — the process family below is memory-hungry
awk '/MemTotal/ {printf "%.1f GB\n", $2/1024/1024}' /proc/meminfo
                                   # want: ~8 GB on ace-control, ~4 GB on ace-exec

# 4. Hostname is real — receptor refuses 'localhost' node names
hostnamectl hostname               # want: ace-control / ace-exec, NOT localhost

# 5. No noexec mounts where code runs — jobs and wheels execute from here
for d in /var /tmp /var/tmp; do
  findmnt -no OPTIONS --target "$d" | grep -q noexec && echo "FAIL: $d is noexec"
done; echo "check done (silence above = OK)"

# 6. /var/log writable and sane
stat -c '%a %U %n' /var/log        # want: 755 root /var/log
```

All six pass = the box is ready. Any fail = fix it now; every one of these produces a confusing failure five labs later if ignored.

Next: [The internal CA](03-internal-ca.md)
