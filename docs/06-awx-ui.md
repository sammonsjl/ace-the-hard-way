# Lab 6 — Building the UI

## What you will have at the end

The AWX web UI built from source and collected into `/var/lib/awx/public/static`, where nginx will serve it in Lab 10.

## Where the UI comes from

The UI is a **separate repo** — `ansible/ansible-ui`, branch **`main`** (the standalone AWX UI; the awx repo only carries the build glue).

This is the one component we do **not** track on `devel`. On `ansible-ui`, `devel` is the next-generation **platform** UI (`@ansible/ui`, Node 20+, built from the `platform/` workflow that fronts the gateway) — it has no `build:awx` script, so AWX's `make ui` cannot build it. The standalone AWX web UI that community AWX ships lives on **`main`** and builds with Node 18 — which is exactly why AWX's UI Makefile defaults to `main`. We leave that default alone. `main` still moves, so record the commit you built.

Two hard facts from the build itself:

- **Node must be 18.x.** AWX's UI Makefile checks the major version and refuses to build on anything else.
- AWX's `make ui` clones `ansible-ui`, builds it, and drops the output at `awx/ui/build` — which is already on AWX's `STATICFILES_DIRS`, so `collectstatic` finds it with no extra wiring.

All commands on **ace-control**. Assumes `git` and `make` from Lab 5 are present.

## Install Node 18

```bash
sudo dnf -y module install nodejs:18/common
node --version        # want: v18.x
npm --version         # record it
```

## Build the UI

`make ui` (from the awx repo) clones `ansible-ui` (branch `main`, its default) into `awx/ui/src`, checks Node 18, installs deps, builds the production bundle, and copies it to `awx/ui/build`. Run it as `awx` in one self-contained shell:

```bash
sudo -u awx bash <<'AWXEOF'
set -euo pipefail
cd /opt/awx
node --version                                    # v18.x, or the build refuses
make ui
git -C awx/ui/src rev-parse --short HEAD           # RECORD THIS — the ansible-ui main commit you built
AWXEOF
```

> The webpack production build is memory-hungry. The 8 GB control VM handles it, but if Node dies with "JavaScript heap out of memory," give it more headroom: `NODE_OPTIONS=--max-old-space-size=4096 make ui` (or raise the VM's RAM).

## Collect static files

`collectstatic` gathers the built UI (plus Django's admin/DRF assets) into `STATIC_ROOT` = `/var/lib/awx/public/static`:

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage collectstatic --noinput --clear
```

## Verify

```bash
# The built UI landed where AWX expects it:
ls /opt/awx/awx/ui/build/awx/index_awx.html          # want: the file exists

# collectstatic populated the static root:
ls /var/lib/awx/public/static/awx/ | head            # want: hashed JS/CSS assets
```

If both list files, the UI is built and staged. nginx will serve `/static` from here in Lab 10.

Next: [Configuring AWX](07-awx-config.md)
