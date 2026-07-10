# Lab 5 — AWX from source

## What you will have at the end

The AWX codebase on the VM, with its Python virtualenv fully built.

## Outline (to be written)

- [ ] Pick + pin an AWX release tag (document WHY pinning matters — devel moves daily)
- [ ] `git clone https://github.com/ansible/awx --branch <tag>`
- [ ] Build deps: `dnf install python3.12 python3.12-devel gcc postgresql-devel libpq-devel` (+ whatever the wheels demand)
- [ ] Create the venv, upgrade pip/setuptools/wheel
- [ ] `pip install -r requirements/requirements.txt` (expect a fight; document each casualty)
- [ ] `pip install -e .` → `awx-manage` exists
- [ ] Verify: `awx-manage --help` runs inside the venv

> This is the chapter containers were invented to avoid. That's exactly why we're doing it.

Next: [Building the UI](06-awx-ui.md)
