# Lab 2 — The host

## What you will have at the end

A state root at `~/ace/`, five names in `/etc/hosts` that all point at your own machine, and one throwaway container running as a systemd user unit you wrote by hand — the exact loop every later lab repeats.

Nothing component-specific. That starts in Lab 4.

## Where everything will live

Three places, and only three:

| | |
|---|---|
| `~/ace/` | every config file, certificate and bit of mutable state, one directory per component |
| `~/.config/containers/systemd/` | one quadlet per container — the unit definitions you write |
| `~/.local/share/containers/` | podman's own image and volume storage |

Nothing is installed into the host. No `/etc`, no `/usr`, no system units, no service accounts. The single exception is `/etc/hosts` below, and Lab 99 puts that back.

```bash
mkdir -p ~/ace
mkdir -p ~/.config/containers/systemd
```

The per-component directories (`~/ace/gateway/`, `~/ace/awx/`, and so on) get created by the lab that needs them, so that an unfinished tutorial leaves no empty scaffolding behind.

> **Why `~/ace/<component>/`?** It is the layout the vendor's containerized installer uses. Matching it means the config paths in these labs line up with a real deployment's, and that when you go looking at one you already know where to look.

## Names

Everything runs in one network namespace — the host's — so every service is reachable at `127.0.0.1`. You could write `127.0.0.1` everywhere and it would work.

Don't. Give them names:

```bash
sudo tee -a /etc/hosts <<'EOF'

# ACE the Hard Way — containerized track. Removed in Lab 99.
127.0.0.1  ace-gateway ace-controller ace-hub ace-eda ace-db
EOF
```

Two reasons, and the second is the real one.

**Configs stay readable.** `POSTGRES_HOST=ace-db` says what it means. `POSTGRES_HOST=127.0.0.1` in four different config files, meaning four different things, does not.

**The certificates stay honest.** [Lab 3](03-internal-ca.md) builds a CA that signs a certificate per component, and a certificate is issued *to a name*. If every name is `localhost`, the whole subject-alternative-name mechanism collapses into a formality you never have to think about — and then you have not learned it. With real names, a certificate whose SAN does not match the host you connected to fails exactly the way it fails in production, and you fix it the same way.

This is the one lesson from the bare-metal track's five machines that survives a single host, and it survives only because of these five lines. It is worth the `sudo`.

## The runtime model

Every service in this tutorial is a container, and every container is a **systemd user unit**. Not `podman run` in a terminal, not a script, not compose.

That means the tools are the ones you already know:

```bash
systemctl --user status ace-postgres
systemctl --user restart ace-gateway
journalctl --user -u ace-controller -f
```

...and it means the platform starts at boot and survives logout, because you turned on lingering in Lab 1. Without it the user manager stops with your session and takes all eleven containers with it. Confirm:

```bash
loginctl show-user "$USER" -p Linger
```

**Want:** `Linger=yes`.

### Quadlets

You do not write `.service` files. You write **quadlets** — a `.container` file describing the container, which systemd's podman generator turns into a service unit at daemon-reload.

```
~/.config/containers/systemd/ace-thing.container   →   ace-thing.service
```

The name is the contract: `ace-thing.container` always becomes `ace-thing.service`, and that is the name you use with `systemctl --user`. There is no separate registration step and nothing to enable — the generator finds the file because of where it is.

> **The vendor's installer uses `podman generate systemd` instead**, which writes a `.service` file once, from a container that already exists. That command is deprecated as of podman 5, and generating a unit from a running container inverts the thing this tutorial is for — the unit should be the source, not the output. Quadlets reach the same end state: a user unit supervising a container. This is the first of three deliberate departures from the bundle; the README lists all three.

## Your first unit

Write a quadlet that does nothing useful, so that when a real one misbehaves you already know which half is broken.

```bash
vim ~/.config/containers/systemd/ace-hello.container
```

```ini
[Unit]
Description=ACE throwaway — proves the quadlet loop works

[Container]
ContainerName=ace-hello
Image=quay.io/rockylinux/rockylinux:9
Exec=sleep infinity

[Service]
Restart=on-failure

[Install]
WantedBy=default.target
```

Systemd has not read it yet. Tell it to, then start the unit:

```bash
systemctl --user daemon-reload
systemctl --user start ace-hello
```

**Every time you edit a quadlet, you `daemon-reload` before restarting.** Skipping it is the single most common way to spend twenty minutes debugging a change that was never loaded. `systemctl --user restart` re-runs the *old* generated unit perfectly happily.

Verify all three layers — the unit, the container, and the process inside it:

```bash
systemctl --user status ace-hello
podman ps
podman exec ace-hello cat /etc/rocky-release
```

**Want:** the unit `active (running)`, one container named `ace-hello` in `podman ps`, and Rocky Linux 9 reported from inside it.

That last command matters more than it looks: the container is EL9 regardless of what your host is. Every image in this tutorial is built on an EL9 base, so from Lab 4 onward the distro under your fingers stops being relevant. This is also the image [Lab 3](03-internal-ca.md) borrows to update a trust store, so pulling it now saves a wait later.

Now take it away:

```bash
systemctl --user stop ace-hello
rm ~/.config/containers/systemd/ace-hello.container
systemctl --user daemon-reload
podman ps -a
```

**Want:** no `ace-hello` anywhere. That is the removal loop from Lab 99, run once on something disposable.

## A note on `:Z`

From Lab 4 onward, every mount into a container looks like this:

```
Volume=%h/ace/awx/conf.d/ace.py:/etc/tower/conf.d/ace.py:ro,Z
```

The `Z` asks podman to relabel that file so SELinux will let the container read it. **On an SELinux host — Fedora, RHEL, Rocky — it is mandatory**, and without it you get a permission denied that has nothing to do with file modes and does not mention SELinux. On a host without SELinux, such as Arch or Debian, it is silently ignored.

The labs write `:Z` everywhere it belongs, so the same command works on either kind of host. It is called out here once rather than repeated as a warning in nine labs.

`%h` is systemd's specifier for your home directory. Quadlets are not shells; `$HOME` and `~` do not expand in them.

## What "no VM" costs you

The bare-metal track ends with `terraform destroy`, and whatever mess the tutorial made goes away with the machines that held it.

You do not have that. The platform is running on a computer you use for other things, so removal is a list, not a command — units disabled, containers removed, volumes removed, images pruned, `~/ace/` deleted, `/etc/hosts` restored. [Lab 99](99-cleanup.md) is that list, and the preflight snapshot you took in Lab 1 is how you check it worked.

Two habits make this painless, and both start now:

- **Everything is named `ace-*`.** Containers, units, volumes, images. When it is time to find what belongs to this tutorial, the prefix is the inventory.
- **Nothing lives outside the three directories above.** If a lab ever seems to want state somewhere else, that is a bug in the lab.

## Verify

```bash
ls -d ~/ace ~/.config/containers/systemd
getent hosts ace-gateway ace-controller ace-hub ace-eda ace-db
loginctl show-user "$USER" -p Linger
podman ps -a
```

**Want:** both directories present, all five names resolving to `127.0.0.1`, `Linger=yes`, and no containers at all — you removed the only one you had.

Next: [The internal CA](03-internal-ca.md)
