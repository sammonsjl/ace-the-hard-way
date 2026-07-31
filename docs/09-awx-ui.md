# Lab 9 — Building the UI

## What you will have at the end

The AWX web UI built from the `ansible-ui` **`devel`** tree as a standalone single-page app, pointed at this box's AWX API, and staged where nginx will serve it in Lab 10. No gateway required.

## Where the UI comes from

The UI is a **separate repo** — `ansible/ansible-ui`, branch **`devel`**, built as a standalone app that talks straight to AWX's own API. This is the newer platform-era UI, but it still ships a standalone AWX build in the `frontend/awx` workspace (`@ansible/awx-ui`), and that build runs **without the gateway**.

How it finds AWX: the workspace's Vite config bakes an `AWX_SERVER` env var into the build and targets `AWX_API_PREFIX = /api/v2` — AWX's own API, not the platform's `/api/controller/v2`. Set `AWX_SERVER` to this host and the SPA calls back to our AWX directly.

Two consequences to know up front:

- **Node must be 20+.** This tree (`@ansible/ui`, `engines: node >=20`) will not install on Node 18. That's the opposite of the older `main` UI — so we switch the Node stream here.
- **We do not use `make ui`.** That target drives the old `main`/`build:awx` path and hard-checks Node 18. We build the `frontend/awx` workspace directly with Vite instead.

> Upstream files standalone mode under "Not Recommended" (the recommended path fronts the gateway). We use it deliberately: it's the AWX UI without Jewel, which is exactly what this stage of the build needs.

> **This is the modern UI, not the old one — and it's not the whole story.** `frontend/awx` is the current React/PatternFly ansible-ui (`AwxMain` bundles), the same codebase and commit as the platform console — *not* the retired AngularJS "classic" AWX UI. What makes it look plainer is only that it's the **single-service standalone** build: AWX logo, controller-only navigation, no Hub or EDA. That's by design here — there's no gateway yet, and `frontend/awx` has zero gateway awareness (it never shows the other services, even if you later served it behind the gateway). The **unified** console — one login, Controller + Hub + EDA in a single nav, Ansible branding — is a *different* build (`@ansible/platform-ui`) that requires the gateway, and it arrives in [Lab 17](17-platform-ui.md). So: this lab gives you a real browser console for the controller-only milestone; Lab 19 is the pivot to the platform UI. (After that pivot the gateway takes port 443 and this standalone UI steps back to `:8043` — see Lab 17.)

All commands on **ace-control**. Assumes `git` from Lab 5 is present.

## Install Node 20

Node 20 ships as a module stream on Rocky 9. Reset the module so the stream resolves cleanly, then install:

```bash
sudo dnf -y module reset nodejs
sudo dnf -y module install nodejs:20/common
node --version        # want: v20.x
npm --version         # record it
```

## Clone `ansible-ui` (devel)

```bash
sudo install -d -o awx -g awx /opt/ansible-ui
sudo -u awx git clone --branch devel https://github.com/ansible/ansible-ui.git /opt/ansible-ui
```

## Build the AWX UI

`npm ci` installs the whole nx monorepo (all workspaces), then we build just the `frontend/awx` workspace. `AWX_SERVER` is baked into the bundle, so set it to the URL nginx will serve this host on (Lab 10 terminates TLS):

```bash
sudo -u awx bash <<'AWXEOF'
set -euo pipefail
cd /opt/ansible-ui
node --version                                   # v20.x, or the install refuses
npm ci                                           # installs the full workspace tree (slow)
export AWX_SERVER="https://192.168.56.10"        # this host; baked into the build
cd frontend/awx
npm run build                                    # vite build -> frontend/awx/dist
git -C /opt/ansible-ui rev-parse --short HEAD    # RECORD THIS — the ansible-ui devel commit you built
AWXEOF
```

> The Vite build is memory-hungry (monaco, PatternFly). The 8 GB control VM should handle it; if Node dies with "JavaScript heap out of memory," give it headroom: `NODE_OPTIONS=--max-old-space-size=4096 npm run build` (or raise the VM's RAM).

## Stage it for nginx

Copy the built SPA to a stable served path under AWX's public dir:

```bash
sudo install -d -o awx -g awx /var/lib/awx/public/ui
sudo -u awx cp -a /opt/ansible-ui/frontend/awx/dist/. /var/lib/awx/public/ui/
```

## Verify

```bash
sudo -u awx ls /var/lib/awx/public/ui/index.html     # want: the SPA entrypoint exists
sudo -u awx ls /var/lib/awx/public/ui/assets | head   # want: hashed JS/CSS bundles
```

If both list files, the UI is built and staged.

## What Lab 10 (nginx) will need

This SPA is served as its own site, not through Django's `collectstatic`. When we set up nginx, it will:

- serve `/var/lib/awx/public/ui` at `/`, with a SPA fallback to `index.html`;
- proxy `/api/` to AWX (uwsgi) — the SPA calls `AWX_SERVER` + `/api/v2`, same origin;
- proxy `/websocket/` to daphne (the build sets `AWX_WEBSOCKET_PREFIX = /websocket/`).

`AWX_SERVER` is baked in at build time. If you later front this host with a hostname instead of `192.168.56.10`, rebuild with the new `AWX_SERVER`.

Next: [nginx front door](10-nginx.md)
