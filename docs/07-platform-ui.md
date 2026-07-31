# Lab 7 — The platform UI

## What you will have at the end

The unified platform console — built from source and dropped into the directory
[Lab 6](06-gateway.md)'s nginx already serves. Log in at `https://192.168.56.10:8443` and you get
a real web UI with a real session.

It will be a fairly empty console: users, teams, organisations, authentication settings. That is
the entire platform right now. Every other section of the navigation appears as a service
registers itself — the controller in [Lab 16](16-service-registration.md), hub and EDA in
Labs 18–19 — and none of them require rebuilding this UI.

```
browser ──► nginx :8443 ──┬── /api/, /o/, /v3/  ──► gateway uwsgi
                          └── everything else   ──► /var/lib/ansible-automation-platform/platform/ui
```

All commands on **ace-control**.

## One UI for the whole platform

Worth being explicit about, because it explains a lab that *isn't* here.

There is no separate console for the controller, or for hub, or for EDA. This one SPA is the
front end for all of them. It discovers what exists by reading the gateway's service registry at
runtime — `GET /api/` returns the list, and the navigation is built from it. Register a service
and its section appears on the next page load.

That is why the controller labs that follow have no UI step in them: there is nothing to build.
A from-source AWX does ship a `ui` Django app, but its `build/index.html` is a stub — the real
console is this one, and it belongs to the gateway.

## Install Node

The build needs a current LTS Node, which Rocky doesn't ship by default:

```bash
sudo dnf -y module reset nodejs
sudo dnf -y module enable nodejs:20
sudo dnf -y install nodejs
node --version && npm --version    # want: v20.x — record both
```

## Clone and build

The UI lives in the `ansible-ui` monorepo. It has several workspaces; the one that builds the
unified console is `platform`:

```bash
sudo install -d -o gateway -g gateway /opt/ansible-ui
sudo -u gateway git clone https://github.com/ansible/ansible-ui.git /opt/ansible-ui
sudo -u gateway git -C /opt/ansible-ui rev-parse --short HEAD   # RECORD THIS
```

```bash
sudo -u gateway bash <<'EOF'
set -euo pipefail
cd /opt/ansible-ui
npm ci --ignore-scripts

cd platform
export PLATFORM_SERVER="https://192.168.56.10"
npm run build          # -> platform/dist
EOF
```

> **No `--omit=dev`.** Vite, its React plugin, and the TypeScript toolchain are all
> *devDependencies* — they are what performs the build, not what ships in it. Omit them and `npm
> ci` succeeds, then the build dies with
> `Cannot find package '@vitejs/plugin-react'`, which reads like a missing dependency in the repo
> rather than one you told npm to skip. The distinction only makes sense from the perspective of
> something *consuming* this package; we are compiling it.
>
> `--ignore-scripts` skips package postinstall hooks, which are mostly tooling this workspace
> doesn't need and add several minutes.
>
> The build is memory-hungry — it bundles Monaco and all of PatternFly — and sets its own
> `NODE_OPTIONS=--max-old-space-size=8192` internally, so there is no point exporting your own. If
> it dies with "JavaScript heap out of memory", the VM needs more RAM.

`PLATFORM_SERVER` is the gateway's public URL. The built SPA makes same-origin calls, so this
mostly feeds the dev server and the websocket base — but set it correctly anyway, because getting
it wrong produces a console that loads and then fails every request with an opaque CORS error.

## Stage it

Copy the built assets into the directory nginx is already configured to serve. It's `root:nginx`
from Lab 6, so this runs as root:

```bash
sudo cp -a /opt/ansible-ui/platform/dist/. /var/lib/ansible-automation-platform/platform/ui/
sudo chown -R root:nginx /var/lib/ansible-automation-platform/platform/ui
sudo restorecon -Rv /var/lib/ansible-automation-platform/platform/ui
ls /var/lib/ansible-automation-platform/platform/ui/index.html   # want: it exists
```

Note what did *not* happen: no nginx config change, no service restart, no route registration.
Lab 6 pointed a `root` and a `try_files` at this directory; filling it in is the whole deployment.

> `collectstatic` in Lab 6 wrote Django's admin assets into `.../platform/ui/static/`. The copy
> above lands alongside it, not over it — the SPA's own assets live in `assets/`. If you ever
> re-run `collectstatic --clear`, it only clears `static/`.

## Verify

```bash
# the SPA is served, and it's HTML rather than a 404:
curl -sk -o /dev/null -w '%{http_code} %{content_type}\n' https://192.168.56.10:8443/
# want: 200 text/html

# the SPA fallback works — a client-side route returns the app, not a 404:
curl -sk -o /dev/null -w '%{http_code}\n' https://192.168.56.10:8443/access/users
# want: 200

# the bundle is real and hashed:
curl -sk https://192.168.56.10:8443/ | grep -oE '/assets/[^"]+\.js' | head -3

# and the API still answers on the same origin:
curl -sk https://192.168.56.10:8443/api/gateway/v1/ping/ | python3 -m json.tool
```

Then open **`https://192.168.56.10:8443`** in a browser and log in with the `admin` account you
created in Lab 6.

Your browser will trust the certificate without a warning *if* you imported
[Lab 3](03-internal-ca.md)'s root CA into it — that is the payoff for building a real CA instead
of a self-signed cert per service. If you skipped that, you get the usual interstitial; the CA
certificate is at
`/etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt`.

What you should see: a working console with **Access Management** (users, teams, organisations,
roles) and **Settings** (authentication). No Automation Execution, no Automation Content, no
Automation Decisions — those are services, and no service has registered yet.

> **Why port 8443 and not 443?** envoy owns 443, and envoy has no listeners: it is polling the
> gateway's registry and the registry is empty. Registering the gateway *as a service* is what
> creates that listener, and that happens in [Lab 16](16-service-registration.md) along with the
> controller. Until then, 8443 — nginx directly — is the front door. Nothing about this lab
> changes when 443 opens; the same nginx block serves both.

## If the console loads but every request fails

Three failure modes, distinguishable from the browser's network tab:

| Symptom | Cause |
|---|---|
| `401` on `/api/gateway/v1/me/`, redirected back to login | session cookie rejected — `CSRF_TRUSTED_ORIGINS` / `FRONT_END_URL` in Lab 6's settings don't match the URL you're using |
| CORS error naming a different origin | `PLATFORM_SERVER` was wrong at build time — rebuild |
| `502` from nginx on `/api/` | gateway uwsgi is down: `sudo supervisorctl status gateway-processes:uwsgi` |

Next: [AWX from source](08-awx-source.md)
