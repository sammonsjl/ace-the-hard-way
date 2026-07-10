# Lab 5 — AWX from source

## What you will have at the end

The AWX source checked out from `devel`, and its Python virtualenv built at `/var/lib/awx/venv/awx` — the same tree the real installer uses — with `awx-manage` runnable inside it.

> Bare metal note: still no containers. The venv is a plain directory of Python packages, built by hand on the box.

## Why `devel` and not a release tag

AAP 2.6 tracks AWX **`devel`**, not a tagged release — so `devel` is the faithful upstream for what we're replicating. We clone the **live tip**.

> **Caveat — this is the one place we knowingly break the repo's "pin everything" rule.** `devel` moves daily, so your build will differ over time and can break without warning. That's the trade for tracking exactly what AAP tracks. If you need a reproducible build, `git checkout <sha>` a specific commit and record it. Either way, note the commit you built (a step below captures it).

## Why we DON'T drive AWX's `make` targets (first-run discovery)

The plan was to run upstream's `make requirements_awx` and `make develop` and let the Makefile be the source of truth. Reality vetoed it, twice:

1. **`make develop` runs the legacy `setup.py develop` path, which clashes with PEP-517 tooling on Python 3.12.** The modern equivalent — `pip install -e .` — does the same job through the standard build backend.
2. **Driving make through `sudo -u awx bash -lc '...'` breaks its nested sub-shells** — see the environment-stripping warning below.

So we transcribe the Makefile's *behavior* into explicit commands — which is more hard-way anyway. What we keep from it: the requirements files to install, the source-only package list, and the venv location.

All commands on **ace-control**.

## Build toolchain

The requirements step compiles several packages from source (`cffi`, `pycparser`, `psycopg` — upstream's `--no-binary` list). These are the headers and libraries that fight ended at:

```bash
sudo dnf -y install \
  gcc gcc-c++ make git \
  python3.12 python3.12-devel \
  libffi-devel openssl-devel \
  libpq-devel postgresql-devel \
  openldap-devel cyrus-sasl-devel
python3.12 --version        # record the exact version
```

> **Why each:** `libffi-devel` → `cffi` needs `ffi.h` (the first compile failure you'll otherwise see); `libpq-devel`/`postgresql-devel` → `psycopg` needs `pg_config` + libpq headers; `openldap-devel` + `cyrus-sasl-devel` → `python-ldap`; `openssl-devel` → several crypto builds. If a *new* casualty appears (devel moves), add its `-devel` package here and log it in **Casualties**.

## Clone `devel`

```bash
sudo install -d -o awx -g awx /opt/awx
sudo -u awx git clone --branch devel https://github.com/ansible/awx.git /opt/awx
cd /opt/awx
git rev-parse --short HEAD  # RECORD THIS — it's the devel commit you built (moving tip)
```

## Build the venv

> **Warning — the `sudo` environment-stripping trap.** Two mechanisms conspire against `sudo -u awx bash -lc '...'`: `sudo`'s default `env_reset` replaces PATH with `secure_path`, and `-l` makes bash a *login* shell that re-reads `/etc/profile` and rebuilds PATH again. Anything you exported — including an activated venv — dies twice, and nested sub-shells (like make spawns) inherit the wreckage. The fix is to stop depending on inherited environment entirely: run a **non-login** shell as `awx` and build the environment *inside* it, starting with `source .../activate`.

Everything below runs inside one privilege-dropped, self-contained shell:

```bash
sudo -u awx bash <<'AWXEOF'
set -euo pipefail
source /var/lib/awx/venv/awx/bin/activate
cd /opt/awx

# 1. Toolchain bootstrap — PEP-517-era versions, so builds behave on 3.12
pip install --upgrade pip setuptools wheel setuptools_scm

# 2. THE REAL DEPENDENCY SET. This is the step you cannot skip (see warning below).
#    Mirrors upstream's Makefile: frozen + git requirements in one resolve,
#    with the C-extension packages compiled from source.
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

> **Warning — `pip install -e .` alone gives you a broken AWX.** The editable install only pulls what `setup.py` *declares*, and AWX declares almost nothing there — the real dependency set lives in `requirements/requirements.txt`. Skip step 2 and everything imports fine until runtime, when you get crashes like:
>
> ```
> ValueError: Cannot resolve 'awx.main.utils.handlers.ColorHandler': No module named 'logutils'
> ```
>
> Requirements first, editable install second. Always.

## Verify

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --version  # records the devel version string
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --help     # want: the command list, no Traceback
```

If `--help` prints the command list, the backend is built. (It can't talk to a database yet — that's Lab 7's `/etc/tower` config and the migrate step later.)

## Casualties (logged from the first run)

- `cffi` compile failed — `ffi.h: No such file or directory` → `libffi-devel` was missing. Added to the toolchain list.
- `make develop` failed — legacy `setup.py` hooks vs PEP-517 on Python 3.12 → replaced with `pip install -e .`.
- `sudo -u awx bash -lc` stripped PATH/env and broke make's sub-shells → replaced with a non-login, self-contained heredoc shell (see warning).
- `awx-manage` crashed at runtime with `No module named 'logutils'` → editable install without the requirements files; fixed by installing `requirements/requirements.txt` + `requirements_git.txt` **before** `pip install -e .`.

Next: [Building the UI](06-awx-ui.md)
