# Lab 2 — Provisioning the VMs

## What you'll have at the end

Two Rocky Linux 9 VMs that can see each other, both passing the installer-grade preflight checks, with the `awx` service user on both and the full filesystem contract laid down on the control node.

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

Create the dedicated `awx` service user everything will run under (no service runs as root). Home is `/var/lib/awx`, matching the RPM install; it gets a real shell because init commands run as this user (`sudo -u awx awx-manage ...`):

```bash
sudo useradd --system --home-dir /var/lib/awx --create-home --shell /bin/bash awx
```

Build the directory tree from the filesystem contract below:

```bash
# home layout: projects, job output, static files, and the venv's future home
sudo mkdir -p /var/lib/awx/{projects,job_status,public/static,venv}

# config root (settings.py, conf.d fragments, SECRET_KEY, certs)
sudo mkdir -p /etc/tower/conf.d

# logs: app logs (awx-owned, 0750) and supervisor's per-process logs
sudo mkdir -p /var/log/tower /var/log/supervisor

sudo chown -R awx:awx /var/lib/awx /etc/tower /var/log/tower
sudo chmod 0750 /var/log/tower
```

`/var/run/tower` (the uwsgi/daphne sockets) lives on a tmpfs — it vanishes every reboot unless systemd recreates it. That's what tmpfiles.d is for:

```bash
sudo tee /etc/tmpfiles.d/tower.conf > /dev/null <<'TMPEOF'
d /var/run/tower 0750 awx awx -
TMPEOF
sudo systemd-tmpfiles --create /etc/tmpfiles.d/tower.conf
```

Update the base system and note the versions — this tutorial pins everything:

```bash
sudo dnf -y update
cat /etc/rocky-release
```

## Prep the execution plane node

`ace-exec` needs exactly one thing today — the same service user (on a real RPM install, receptor runs as `awx` on execution nodes too). Everything else (receptor, podman, TLS) is Lab 12's job:

```bash
exit                       # leave ace-control
vagrant ssh ace-exec
sudo useradd --system --home-dir /var/lib/awx --create-home --shell /bin/bash awx
sudo dnf -y update
```

Run the preflight checks below on this VM as well before you leave it.

## Verify

```bash
# from ace-control:
ping -c1 192.168.56.20              # execution plane reachable
# from ace-exec:
ping -c1 192.168.56.10              # control plane reachable the other way
id awx                              # service user exists
sudo -u awx bash -c 'echo $HOME'    # /var/lib/awx
ls -ld /var/run/tower               # exists, awx:awx, 0750
sudo reboot                         # ...then check /var/run/tower again — tmpfiles.d proof
```

## The filesystem contract (matches the real RPM install exactly)

One user, five directories — identical to production AAP, so everything you learn here transfers:

| Path | Owner | Purpose |
|---|---|---|
| `/var/lib/awx` | awx:awx | home: venv (`venv/awx/`), `projects/`, `job_status/`, `public/static/` |
| `/etc/tower` | awx:awx | `settings.py`, `conf.d/*.py`, `SECRET_KEY` (0400), TLS cert/key |
| `/var/run/tower` | awx:awx | uwsgi + daphne sockets (needs tmpfiles.d — they vanish on reboot) |
| `/var/log/tower` | awx:awx (0750) | application logs |
| `/var/log/supervisor` | root | per-process supervisor logs |

(Commands for all of this are in "Prep the control node" above.)

## Preflight checks (adopted from the real installer)

The real installer refuses to proceed if any of these fail. Run them all on BOTH VMs:

```bash
# 1. Time sync — clock skew breaks TLS handshakes and job timestamps
systemctl is-active chronyd        # want: active   (if not: sudo dnf -y install chrony && sudo systemctl enable --now chronyd)
chronyc tracking | head -3         # want: a real reference ID, small offset

# 2. UTF-8 locale — non-UTF-8 breaks Django and postgres init
locale | grep -c 'UTF-8'           # want: > 0, no errors printed

# 3. Enough RAM — the installer enforces a minimum
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

All six pass = the box is installer-grade. Any fail = fix it now; every one of these produces a confusing failure five labs later if ignored.

Next: [PostgreSQL](03-postgresql.md)
