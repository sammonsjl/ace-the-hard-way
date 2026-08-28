# Cleanup

Removing everything this tutorial built.

On the [bare-metal track](../../../tree/main/docs/99-cleanup.md) this is one command — `terraform destroy` — and whatever mess the labs made goes away with the machines that held it.

You do not have that. The platform ran on a computer you use for other things, so removal is a list. The good news is that the list is short and complete, because every lab put its state in one of three places and named everything `ace-*`.

> **Save anything you want to keep first** — admin passwords, the CA, any content you pushed to hub. All of it is inside `~/ace/`, and all of it is about to be deleted.

## 1. Stop and remove the units

```bash
systemctl --user list-units 'ace-*' --all --no-legend
```

That is your inventory. Stop all of it:

```bash
systemctl --user stop 'ace-*'
```

Quadlet-generated units are not enabled in the usual sense — there is nothing in `~/.config/systemd/user/` to unlink. Removing the `.container` file *is* removing the unit:

```bash
rm -f ~/.config/containers/systemd/ace-*.container
rm -f ~/.config/containers/systemd/ace-*.network
rm -f ~/.config/containers/systemd/ace-*.volume
systemctl --user daemon-reload
systemctl --user reset-failed 'ace-*'
```

**Want:** `systemctl --user list-units 'ace-*' --all --no-legend` now prints nothing.

> **`reset-failed` is what makes that true.** A unit stopped mid-run is recorded as failed, and systemd keeps that failure state even after the quadlet defining it is gone — so the units come back in `list-units` as `not-found failed failed` indefinitely. [Lab 2](02-host.md) demonstrates this on a throwaway unit. Skip it and step 5 below never comes back clean.

## 2. Remove the containers, volumes and images

```bash
podman ps -a --filter 'name=ace-'
podman rm -f $(podman ps -aq --filter 'name=ace-') 2>/dev/null || true

podman volume ls
podman volume rm $(podman volume ls -q --filter 'name=ace') 2>/dev/null || true
```

Images are the bulk of the disk. Remove the ones you built, then everything unreferenced:

```bash
podman images
podman rmi -f $(podman images -q 'localhost/ace-*') 2>/dev/null || true
podman system prune -a --volumes
```

> `podman system prune -a` removes **every** image not used by a running container, not just this tutorial's. If you build other things with podman on this machine, list images first and remove them by name instead.

Reclaim the storage and confirm:

```bash
podman system df
```

## 3. Remove the state root

```bash
rm -rf ~/ace
```

This takes the CA and its private key, every service certificate, every config file you wrote, and the extracted trust bundle. There is nothing under `~/ace/` that anything else on your system uses.

## 4. Put `/etc/hosts` back

[Lab 2](02-host.md) appended a comment line and one entry. Remove both:

```bash
sudo vim /etc/hosts
```

Delete the `# ACE the Hard Way` comment and the `127.0.0.1  ace-gateway ace-controller ace-hub ace-eda ace-db` line beneath it.

```bash
getent hosts ace-gateway
```

**Want:** no output.

## 5. Check your work against the preflight

This is why [Lab 1](01-prerequisites.md) took a snapshot before you started, into `~/.ace-preflight/` — outside `~/ace/`, precisely so it would survive step 3.

```bash
diff <(cp /etc/hosts /dev/stdout) ~/.ace-preflight/hosts.txt
diff <(podman ps -a) ~/.ace-preflight/containers.txt
diff <(systemctl --user list-units --all --no-legend) ~/.ace-preflight/units.txt
```

**Want:** no differences in the first two. The unit list will differ — a desktop session's units come and go — but no line in it should contain `ace-`.

Ports, last:

```bash
for p in 443 8443 8444 8445 8446 8080 8081 8082 8083 8050 8051 8052 8000 8001 5432 6379 27199 50051; do
  ss -ltn | grep -qE ":$p " && echo "STILL IN USE: $p"
done
```

**Want:** no output — or only the ports that were already in use when you ran the same check in Lab 1.

Then remove the snapshot itself:

```bash
rm -rf ~/.ace-preflight
```

## What stays

Two things, deliberately:

- **podman**, and its packages. You installed those; remove them with your package manager if you want to, but nothing in this tutorial depends on their absence.
- **Lingering.** `loginctl disable-linger "$USER"` turns it back off. Leave it on if you run anything else as a user unit.

Your `~/.local/share/containers/` directory remains, now empty of this tutorial's layers. That is podman's own storage, not ours.
