# Lab 1 — Prerequisites

## What you'll have at the end

A host that can build and run the platform, and a written record of what that host looked like before you started — so [Lab 99](99-cleanup.md) can prove you put it back.

## What you need

| | |
|---|---|
| **OS** | Linux with a systemd **user** session. Rootless podman and user units are the entire runtime model; there is no VM to hide in. |
| **RAM** | **16 GB minimum.** About 11 containers run at once, and the console build alone asks for 8 GB of heap. You will not build and run at the same time — see below. |
| **Disk** | ~60 GB free, most of it image layers and build caches. |
| **CPU** | 4 cores is workable, 8 is comfortable. Two of the builds are long compiles. |
| **Network** | Builds pull from GitHub, PyPI, npm, quay.io, docker.io and the CentOS mirrors. Nothing here works air-gapped. |

You do **not** need a hypervisor, a cloud account, a registry login, or a spare machine. That is the point of this track.

> **This was tested on Arch.** The commands below are correct for other distros as far as package names go, but only the Arch path has been run end to end. Everything from Lab 4 onward happens *inside containers* and is identical everywhere.

## Install podman

*Arch* — the host this was tested on:

```bash
sudo pacman -S --needed podman
```

*Fedora / RHEL family* — untested as a host:

```bash
sudo dnf -y install podman
```

*Ubuntu / Debian* — untested as a host:

```bash
sudo apt update
sudo apt install -y podman
```

> **Podman must be 4.4 or newer**, because this tutorial writes quadlets and that is when podman learned to read them. 5.x or 6.x is better still: `podman generate systemd`, which the vendor's installer uses, is deprecated from podman 5 onward, and this tutorial does not use it. Check with `podman --version`.

### If you already have Docker

You can keep it. Podman is daemonless, keeps its own image store under `~/.local/share/containers`, brings its own network stack, and does not touch the Docker socket. The two coexist on one machine without any arrangement between them.

Two things would break that, and neither is installed by default:

- **Do not install `podman-docker`.** It aliases the `docker` command to podman. Every Docker workflow you already have would silently start running somewhere else.
- **`DOCKER_HOST` stays unset.** Pointing it at podman's socket is what actually makes the two collide; nothing in this tutorial needs it.

> **You will need `podman.socket` in [Lab 9](09-eda.md)**, and it is safe to enable. It is podman's API endpoint, and it lives at `/run/user/$UID/podman/podman.sock` — a different path, owned by you, from Docker's `/var/run/docker.sock`, which is root-owned and belongs to the `docker` group. Enabling one does not touch the other.

> If networking behaves strangely later — a container that cannot reach another container, or DNS that resolves everywhere except inside podman — suspect Docker first. Its daemon writes its own iptables chains and has a long history of interfering with bridges it does not own.

### Why podman and not Docker

Docker builds every image in this tutorial perfectly well; a Containerfile *is* a Dockerfile. The runtime half is where it stops. This tutorial uses podman secrets, quadlets, `userns: keep-id`, one systemd **user unit** per container, and receptor shelling out to `podman` to start execution environments. Docker's daemon model has no equivalent for any of those. Its answer is compose — a second orchestrator with its own opinions, which is exactly the thing this tutorial exists not to hand you.

## Turn on lingering

```bash
loginctl enable-linger "$USER"
```

Every service you build runs as a **systemd user unit**. Without lingering, the user manager is torn down when your last session ends — so the whole platform would stop the moment you log out, and would not come back at boot. One command, and it is the difference between a platform and a demo.

## Rootless prerequisites

These are almost certainly already true. Check rather than assume:

```bash
grep "^$USER" /etc/subuid /etc/subgid
stat -fc %T /sys/fs/cgroup
```

**Want:** a range in both files (something like `you:100000:65536`), and `cgroup2fs`.

Subordinate UID and GID ranges are what let a rootless container believe it has a root user; without them `podman` fails immediately on any image that does not run as your own UID. Modern distros write them when the account is created. If either file has no line for you, add one with `sudo usermod --add-subuids 100000-165535 --add-subgids 100000-165535 "$USER"` and log out and back in.

`cgroup2fs` is cgroups v2, which rootless resource control requires. Anything current has it.

## Build and run are not simultaneous

The console build stage (`ansible-ui`, in [Lab 5](05-gateway.md)) runs node with `--max-old-space-size=8192`. The controller image builds a virtualenv and compiles C extensions. Meanwhile the running platform is about eleven containers with two Django applications in it.

On 16 GB, either of those is comfortable. Both at once is not. Build images first, then start things — the labs are ordered so that falls out naturally, but it is worth knowing why if you ever wonder whether you can rebuild the gateway while the platform is up. You can't.

## Preflight — record the host as it is now

Everything this tutorial creates lives in three places: `~/ace/`, a set of systemd user units, and podman's own storage. [Lab 99](99-cleanup.md) removes all three. This snapshot is what you diff against to know it worked.

```bash
mkdir -p ~/.ace-preflight
ss -ltnp > ~/.ace-preflight/ports.txt
systemctl --user list-units --all --no-legend > ~/.ace-preflight/units.txt
cp /etc/hosts ~/.ace-preflight/hosts.txt
podman ps -a > ~/.ace-preflight/containers.txt
podman images > ~/.ace-preflight/images.txt
```

It lives in `~/.ace-preflight/`, not `~/ace/`, precisely so that removing the platform does not remove the evidence.

### Ports this tutorial will take

Check them now, while the answer is still "nothing":

```bash
for p in 443 8443 8444 8445 8446 8080 8081 8082 8083 8050 8051 8052 8000 8001 5432 6379 27199 50051; do
  ss -ltn | grep -qE ":$p " && echo "IN USE: $p"
done
```

**Want:** no output.

Anything printed here is a collision you must resolve before Lab 4, and the two likely candidates are a PostgreSQL or Redis you already run. Either stop it for the duration, or change that component's port — every one of these numbers is a variable in a config file you write yourself, so moving one is a one-line edit rather than a fork of the tutorial.

## Verify

```bash
podman --version
podman run --rm quay.io/podman/hello
loginctl show-user "$USER" -p Linger
```

**Want:** podman 4.4 or newer, a greeting from the hello container, and `Linger=yes`.

If you kept Docker, confirm it is unharmed:

```bash
docker version    # or `sudo docker version`, if that is how you normally run it
```

**Want:** a server version. If you get `permission denied ... /var/run/docker.sock` and you are not in the `docker` group, that is how it behaved before you installed podman too — check with `id -nG` before blaming the install.

## Why no VM?

The [bare-metal track](../../../tree/main/docs/01-prerequisites.md) needs five virtual machines because its services install *into* a machine: files under `/usr`, a system `awx` user, units in `/etc/systemd/system`, state in `/var/lib/awx`. You cannot do that to a computer you use for anything else, so you build disposable ones.

Containerizing removes the reason. Every service lives inside an image; everything mutable lives under `~/ace/`; every process is supervised by a user unit you own. Nothing is installed into the host but podman itself. The platform becomes something you can run on the machine in front of you and then genuinely delete — which is why the preflight above exists, and why Lab 99 is a real lab on this track rather than a footnote.

What you give up is the seams. On five machines, "the controller talks to the database" is a hostname, a port, a firewall rule and a certificate whose SAN has to match — and when it breaks you find out which. Here it is a port on loopback. That lesson belongs to the bare-metal track, and it is worth having; this track spends its budget on a different one — what is actually inside the images everybody else pulls.

Next: [The host](02-host.md)
