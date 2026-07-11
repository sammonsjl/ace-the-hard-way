# Lab 5 — AWX from source

## What you will have at the end

The AWX source checked out from `devel`, and its Python virtualenv built at `/var/lib/awx/venv/awx` — the same tree the real installer uses — with `awx-manage` runnable inside it.

> Bare metal note: still no containers. The venv is a plain directory of Python packages, built by hand on the box.

## Why `devel` and not a release tag

AAP 2.6 tracks AWX **`devel`**, not a tagged release — so `devel` is the faithful upstream for what we're replicating. We clone the **live tip**.

> **Caveat — we track `devel` across the platform sources, not just here.** AAP is built from these upstreams' devel branches, so most of the source components in this tutorial (AWX now; the gateway and others later) follow the live tip rather than a pinned tag. The trade is reproducibility: `devel` moves daily, so a build that works today can break tomorrow, and two readers can end up with different source. The hedge is the commit-recording step below — note the SHA you built, so your exact build stays reproducible even as the branch keeps moving.

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
cd /opt/awx
git rev-parse --short HEAD  # RECORD THIS — it's the devel commit you built (moving tip)
```

## Build the venv

Run the whole build inside one privilege-dropped, non-login shell as `awx`, so the environment is self-contained — activate the venv first, then build inside it:

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

## Verify

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --version  # records the devel version string
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --help     # want: the command list, no Traceback
```

If `--help` prints the command list, the backend is built. (It can't talk to a database yet — that's Lab 6's `/etc/tower` config and the migrate step later.)

## Put `awx-manage` in the PATH — like the RPM does

On a real AAP box you type `awx-manage` anywhere and it works: the RPM ships a wrapper at **`/usr/bin/awx-manage`** that execs the venv binary. The installer's own tasks call that bare `awx-manage` (always as the `awx` user — `become_user: awx` on every single task). Hand-write the same wrapper, with one upgrade for our from-source build: bake in `AWX_MODE=production`, because upstream source defaults to *development* mode and any process that loses that variable loads the wrong settings and dies in strange ways (see Lab 8's warning):

```bash
sudo tee /usr/bin/awx-manage >/dev/null <<'EOF'
#!/bin/bash
# hand-written stand-in for the RPM's /usr/bin/awx-manage wrapper
export AWX_MODE=production
export HOME=${HOME:-/var/lib/awx}
exec /var/lib/awx/venv/awx/bin/awx-manage "$@"
EOF
sudo chmod 0755 /usr/bin/awx-manage

sudo -u awx awx-manage --version    # works from anywhere now
```

Why `/usr/bin` and not `/usr/local/bin`: `sudo`'s `secure_path` on Rocky does not include `/usr/local/bin`, so `sudo -u awx awx-manage` would fail with "command not found" — a trap you'd hit constantly. The RPM uses `/usr/bin`; so do we.

Why still `sudo -u awx`: it's in the PATH for *everyone*, but the config (`/etc/tower`, `SECRET_KEY`) is readable only by `awx` — that's deliberate. Root can read anything, so plain `sudo awx-manage` also works; what you can't do is run it as your login user. Same as a real AAP box.

> Labs 6–14 spell out the full `sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage ...'` form so they work even without this wrapper — but with it, every one of those collapses to `sudo -u awx awx-manage ...`.

Next: [Configuring AWX](06-awx-config.md)
