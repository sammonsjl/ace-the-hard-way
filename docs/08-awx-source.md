# Lab 8 — AWX from source

## What you will have at the end

The AWX source checked out from `devel`, and its Python virtualenv built at `/var/lib/awx/venv/awx` — inside the service user's home, alongside everything else AWX owns — with `awx-manage` runnable inside it.

## Why `devel` and not a release tag

ACE builds what upstream is actually shipping today, not a snapshot of what it shipped months ago. Release tags are cut against AWX's containerised deployment story; `devel` is where the code — and the packaging behaviour this tutorial leans on — actually lives. So we clone the **live tip**.

> **Caveat — we track `devel` across every source component, not just here.** The gateway, hub, and EDA labs do the same, because several of them have no meaningful release tags at all. The trade is reproducibility: `devel` moves daily, so a build that works today can break tomorrow, and two readers can end up with different source. The hedge is the commit-recording step below — note the SHA you built, so your exact build stays reproducible even as the branch keeps moving.

## Building without AWX's `make` targets

We transcribe the Makefile's behavior into explicit commands instead of running `make requirements_awx` / `make develop`. Two corrections vs. the obvious `make` path:

1. Use `pip install -e .`, not `make develop`.
2. Run the build in one self-contained, non-login shell as `awx` (see the build step), not `sudo -u awx bash -lc '...'`.

What we keep from the Makefile: the requirements files to install, the source-only package list, and the venv location.

All commands on **ace-control**.

## Build toolchain

The requirements step compiles several packages from source (`cffi`, `pycparser`, `psycopg` — upstream's `--no-binary` list). These are the headers and libraries the build needs:

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel
python3.12 --version        # record the exact version
```

> **What each is for:** `libffi-devel` → `cffi` (`ffi.h`); `libpq-devel`/`postgresql-devel` → `psycopg` (`pg_config` + libpq headers); `openldap-devel` + `cyrus-sasl-devel` → `python-ldap`; `openssl-devel` → several crypto builds. If devel adds a new C-extension later, install its matching `-devel` package here.

## Clone `devel`

```bash
sudo install -d -o awx -g awx /opt/awx
sudo -u awx git clone --branch devel https://github.com/ansible/awx.git /opt/awx
sudo -u awx git -C /opt/awx rev-parse --short HEAD  # RECORD THIS — it's the devel commit you built (moving tip)
```

## Build the venv

Create the venv first, at the path from the Lab 2 filesystem contract (`/var/lib/awx/venv/awx`, inside the `venv/` directory):

```bash
sudo -u awx python3.12 -m venv /var/lib/awx/venv/awx
```

Then run the whole build inside one privilege-dropped, non-login shell as `awx`, so the environment is self-contained — activate the venv first, then build inside it:

```bash
sudo -u awx bash <<'AWXEOF'
set -euo pipefail
source /var/lib/awx/venv/awx/bin/activate
cd /opt/awx

# 1. Toolchain bootstrap — PEP-517-era versions, so builds behave on 3.12
pip install --upgrade pip setuptools wheel setuptools_scm

# 2. Install the full dependency set — frozen + git requirements in one resolve,
#    C-extension packages compiled from source. Run this before the editable install.
cat requirements/requirements.txt requirements/requirements_git.txt \
  | pip install --no-binary cffi,pycparser,psycopg -r /dev/stdin

# 3. Upstream removes a few legacy packages after installing:
if [ -f requirements/requirements_tower_uninstall.txt ]; then
  pip uninstall -y -r requirements/requirements_tower_uninstall.txt || true
fi

# 4. Editable install of AWX itself (the modern 'make develop')
pip install -e .
AWXEOF
```

## Make it a release build, not a checkout — delete `devonly`

This one line is the difference between a working controller and one where **every job you launch hangs in `pending` forever**, and nothing in the logs obviously says why. AWX decides development-vs-production *not* from `AWX_MODE`, but from a single marker file — `awx/__init__.py` does `import awx.devonly` and sets `MODE = 'development'` if it succeeds. That file (`awx/devonly.py`) ships in a **source checkout** and is stripped from the **release package**. Its own header says so: *"This file should only be present in a source checkout, and never in a release package."*

We want the release end state, not a developer checkout, so remove it — exactly what AWX's own packaging build does:

```bash
sudo rm -f /opt/awx/awx/devonly.py
```

> **Why it's fatal, and why it hides.** `MODE` gates the task manager. `awx/main/scheduler/tasks.py` runs the real scheduling only past this guard:
> ```python
> if MODE == 'development' and settings.AWX_DISABLE_TASK_MANAGERS:
>     return          # skip scheduling
> manager().schedule()
> ```
> With `devonly` present, `MODE` is `'development'` **even though you export `AWX_MODE=production` everywhere** — the env var picks the settings files, but `MODE` is decided by that import. So the guard evaluates `settings.AWX_DISABLE_TASK_MANAGERS`, which **doesn't exist in production settings** (it's only defined in `development_defaults.py`). The scheduled `task_manager` task raises `AttributeError` on every tick, the dispatcher swallows it as a failed task, and your jobs sit in `pending` while the rest of the stack looks perfectly healthy — API up, mesh up, `list_instances` green. Deleting `devonly` makes `MODE = 'production'`, the guard short-circuits before touching the missing setting, and `manager().schedule()` runs. (This is the same `AttributeError: ... AWX_DISABLE_TASK_MANAGERS` noted in Lab 11's war story — same root cause, and this is its real fix.)

## Verify

Confirm the build with a **settings-free** check — reading the installed package metadata, which touches nothing under `/etc/tower`:

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/pip show awx   # record the Version line
# Version: 24.6.2.dev881+gf1a3e13df   <- the +g<sha> is the devel commit you cloned
```

(Equivalently, `sudo -u awx /var/lib/awx/venv/awx/bin/python -c "import awx; print(awx.__version__)"` — same string, and importing `awx` doesn't load Django settings.)

**Don't try `awx-manage` yet — not even `--version`.** With `devonly` gone the interpreter is in production mode, and *every* `awx-manage` invocation dies until Lab 9 writes `/etc/tower/settings.py`:

```
django.core.exceptions.ImproperlyConfigured: No AWX configuration found at
['/etc/tower', '/etc/ansible-automation-platform/', '/etc/tower/conf.d/'].
```

The reason it catches even `--version`: `awx-manage`'s entry point calls `prepare_env()` *first*, and current `devel`'s `prepare_env()` reads `settings.DEBUG` (`awx/__init__.py`) — which forces the settings module to import and raise, before the `--version` fast-path in `manage()` is ever reached. That error IS the build working; the full command list runs at the end of Lab 9.

> **Devel caveat, live.** This very step used to be `awx-manage --version`, which printed the version before Django initialized — until upstream added that `settings.DEBUG` read to `prepare_env()` and it started failing. Exactly the "`devel` moves daily" risk from the top of this lab, which is why you recorded the commit SHA above — your build is pinned even though the branch isn't.

## Put `awx-manage` in the PATH

A venv-only install means typing the full `/var/lib/awx/venv/awx/bin/awx-manage` every time, and every doc and forum answer you'll ever read just says `awx-manage`. Close the gap with a small wrapper at **`/usr/bin/awx-manage`** that execs the venv binary, and bake in `AWX_MODE=production` while we're here. Removing `devonly` above fixed the code-path `MODE`; `AWX_MODE=production` is the *other* half — it selects which settings files load (`/etc/tower` + postgres, not the dev sqlite defaults). A process that loses it loads the wrong settings and dies in strange ways (see Lab 11's warning):

```bash
sudo tee /usr/bin/awx-manage >/dev/null <<'EOF'
#!/bin/bash
# hand-written PATH wrapper for the venv's awx-manage
export AWX_MODE=production
export HOME=${HOME:-/var/lib/awx}
exec /var/lib/awx/venv/awx/bin/awx-manage "$@"
EOF
sudo chmod 0755 /usr/bin/awx-manage

sudo -u awx awx-manage --version 2>&1 | tail -1
# want (for now): "...No AWX configuration found at ['/etc/tower', ...]"
# That error is the wrapper WORKING: production mode reads /etc/tower, which
# Lab 9 hasn't written yet. Re-run after Lab 9 and it prints the version.
```

Why `/usr/bin` and not `/usr/local/bin`: `sudo`'s `secure_path` on Rocky does not include `/usr/local/bin`, so `sudo -u awx awx-manage` would fail with "command not found" — a trap you'd hit constantly.

Why still `sudo -u awx`: it's in the PATH for *everyone*, but the config (`/etc/tower`, `SECRET_KEY`) is readable only by `awx` — that's deliberate. Root can read anything, so plain `sudo awx-manage` also works; what you can't do is run it as your login user.

> Labs 9–17 spell out the full `sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage ...'` form so they work even without this wrapper — but with it, every one of those collapses to `sudo -u awx awx-manage ...`.

Next: [Configuring AWX](09-awx-config.md)
