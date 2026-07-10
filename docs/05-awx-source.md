# Lab 5 — AWX from source

## What you will have at the end

The AWX source checked out from `devel`, and its Python virtualenv built at `/var/lib/awx/venv/awx` — the same tree the real installer uses — with `awx-manage` runnable inside it.

> Bare metal note: still no containers. The venv is a plain directory of Python packages, built by hand on the box.

## Why `devel` and not a release tag

AAP 2.6 tracks AWX **`devel`**, not a tagged release — so `devel` is the faithful upstream for what we're replicating. We clone the **live tip**.

> **Caveat — this is the one place we knowingly break the repo's "pin everything" rule.** `devel` moves daily, so your build will differ over time and can break without warning. That's the trade for tracking exactly what AAP tracks. If you need a reproducible build, `git checkout <sha>` a specific commit and record it. Either way, note the commit you built (a step below captures it).

## Why we drive AWX's `make` targets

The `Makefile` is upstream's own build recipe. It already encodes everything we'd otherwise hand-copy and get wrong: Python 3.12, the pinned bootstrap (`pip`, `setuptools`, `setuptools_scm`, `wheel`, `cython`), the `requirements.txt` + `requirements_git.txt` install, the four source-only packages that must compile (`cffi`, `pycparser`, `psycopg`, `twilio`), and the `awx-manage` entrypoint via `setup.py develop`. Transcribing all that by hand would drift the moment upstream bumps a pin — so we run the targets and let the Makefile stay the source of truth. The default `VENV_BASE` is `/var/lib/awx/venv`, which is exactly where we want it.

All commands on **ace-control**.

## Build toolchain

```bash
sudo dnf -y install git make gcc gcc-c++ python3.12 python3.12-devel
python3.12 --version        # record the exact version
```

> **Lean-lab note:** the requirements step compiles a few packages from source. If a compile dies on a missing header or library, that's a casualty — add the right `-devel` package to the line above and log it in **Casualties** at the bottom. We are deliberately *not* pre-listing them; hitting them is the lesson.

## Clone `devel`

```bash
sudo install -d -o awx -g awx /opt/awx
sudo -u awx git clone --branch devel https://github.com/ansible/awx.git /opt/awx
cd /opt/awx
git rev-parse --short HEAD  # RECORD THIS — it's the devel commit you built (moving tip)
```

## Build the venv (make target)

```bash
sudo -u awx make requirements_awx
```

This creates `/var/lib/awx/venv/awx`, installs the pinned bootstrap, then installs `requirements.txt` + `requirements_git.txt` — compiling `cffi`, `pycparser`, `psycopg`, and `twilio` from source (`--no-binary`) — and finally uninstalls the tower-uninstall list. It takes a while, and this is where the fight happens.

## Install `awx-manage` (editable)

```bash
sudo -u awx bash -lc 'source /var/lib/awx/venv/awx/bin/activate && cd /opt/awx && make develop'
```

Activating the venv first is the trick: it makes the Makefile's `PYTHON` resolve to the venv's `python3.12`, so `setup.py develop` installs AWX **into the venv**, not the system Python.

## Verify

```bash
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --help     # want: the awx-manage command list
sudo -u awx /var/lib/awx/venv/awx/bin/awx-manage --version  # records the devel version string
```

If `--help` prints the command list, the backend is built. (It can't talk to a database yet — that's Lab 7's `/etc/tower` config and the migrate step later.)

## Casualties (fill in as you hit them)

Log each build failure and its fix here so it can become a reader warning:

- _(example) `psycopg` build failed — `pg_config` not found → `sudo dnf -y install libpq-devel`, re-run._
- _..._

Next: [Building the UI](06-awx-ui.md)
