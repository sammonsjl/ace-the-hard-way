# Appendix Lab A1 — Breaking uwsgi on purpose (the EPEL conflict)

> Do this AFTER Lab 5 passes. This lab deliberately breaks your working platform, diagnoses it, fixes it, and then makes the breakage impossible. It reproduces a real production failure mode: EPEL's uwsgi clobbering the platform's own.

## What you will have at the end

A platform that survives `dnf update` with EPEL enabled — and a deep understanding of WHY two builds of the same open source uwsgi are not interchangeable.

## The theory (write this up properly)

- pip-installed uwsgi (ours, in the venv) is a **monolithic** build: the venv's Python interpreter is compiled INTO the binary. That's why it can import awx and load the venv's C extensions (psycopg, cryptography) — same interpreter, same ABI.
- EPEL's uwsgi is a **modular** system build: the core binary has no Python; `uwsgi-plugin-python3` links the *system* Python. Different interpreter under a venv full of extensions compiled for another one → ImportError at best, segfaults at worst.
- Version drift stacks on top: AWX pins a uwsgi version matched to its ini options; EPEL ships whatever is current.

## Outline (to be written)

### Part 1 — Break it

- [ ] `dnf install epel-release`
- [ ] `dnf install uwsgi uwsgi-plugin-python3` — note what lands in `/usr/sbin/uwsgi`
- [ ] Simulate the failure a PATH-resolved uwsgi would cause: point a copy of `awx-uwsgi.service` at `/usr/sbin/uwsgi` and start it
- [ ] Collect the evidence: journal errors, the ImportError/ABI failure

### Part 2 — Diagnose like it's production

- [ ] `uwsgi --version` vs venv `uwsgi --version`
- [ ] Which Python is embedded: `strings`/`ldd` on both binaries, `uwsgi --python-version` if it'll even start
- [ ] Show the venv extension ABI: `ls venv/lib/python3.*/site-packages/*.so` — compiled for whom?
- [ ] Write the one-paragraph incident summary (what broke, why, fix) — tutorial gold

### Part 3 — Fix it and armor it

- [ ] Restore the unit to the absolute venv path (our design was already resistant — explain why absolute paths in units matter)
- [ ] `excludepkgs=uwsgi*` in `/etc/yum.repos.d/epel.repo` (per-repo — the right scope: block EPEL's, allow anything else)

```ini
[epel]
...
excludepkgs=uwsgi*
```

- [ ] Verify: `dnf list --showduplicates 'uwsgi*'` shows nothing offered from epel; `dnf install uwsgi` now fails
- [ ] Mention the alternatives and when to use them: global `excludepkgs` in `/etc/dnf/dnf.conf` (blunt), `dnf versionlock` (pin, don't block)
- [ ] `dnf update` full run — platform still up afterwards

## Diagnosis checklist (works in the lab AND in production)

Run these in order — each one narrows it down:

1. **Which binary is actually running?**
   ```bash
   ps -ef | grep uwsgi | grep -v grep
   ```
   Path says everything: `/var/lib/awx/venv/awx/bin/uwsgi` = correct; `/usr/sbin/uwsgi` = swapped.

2. **Who owns the files?**
   ```bash
   rpm -qf /usr/sbin/uwsgi                       # exists at all? whose package?
   dnf list installed 'uwsgi*' 'supervisor*'     # the @repo column: @epel = red flag
   ```

3. **Did an update swap it? (the smoking gun)**
   ```bash
   dnf history list 'uwsgi*' 'supervisor*'
   dnf history info <transaction-id>             # shows the exact swap and the repo it came from
   ```

4. **Prove the interpreter mismatch:**
   ```bash
   /var/lib/awx/venv/awx/bin/uwsgi --version
   strings /usr/sbin/uwsgi | grep -oE 'python3\.[0-9]+' | sort -u   # embedded/linked python
   ldd /usr/lib64/uwsgi/python3_plugin.so 2>/dev/null | grep libpython
   ```
   Compare against the venv's Python: `ls /var/lib/awx/venv/awx/lib/`

5. **Read the failure signature:**
   ```bash
   tail -50 /var/log/supervisor/awx-uwsgi.log
   ```
   `ImportError: No module named awx` → wrong interpreter, no venv on its path. `undefined symbol` / `wrong ELF class` on a `.so` → ABI mismatch. Instant worker exits → same story.

6. **Audit the repos:**
   ```bash
   dnf repolist enabled | grep -i epel
   grep -rn excludepkgs /etc/yum.repos.d/epel*.repo   # empty = unprotected
   ```

**Recovery:** `dnf history undo <id>` (or `dnf downgrade`/`reinstall` the clobbered package), add `excludepkgs`, restart the controller service, THEN re-run whatever update started it.

## This is not a hypothetical

Packaged automation platforms armor against this exact failure, which is the strongest evidence that it's real:

- They ship their **own private EPEL rebuild** as a dependencies repo, rather than pointing at EPEL proper. Packages like `supervisor` then exist under the SAME NAME in two repos, and which one you get is a version race.
- Their repo files set `priority=1`, `module_hotfixes=1`, and an `exclude=` list covering the platform's own packages — cross-repo races are expected and defended against by default.
- uwsgi is deliberately kept INSIDE the venv, married to the interpreter it was compiled against, precisely so a system-wide uwsgi can never be substituted for it.

Our `excludepkgs` fix on the EPEL side is the same defence, applied from the other direction. Enabling EPEL on a box like this without excludes is playing version-number roulette with same-name packages.

## Production note

This failure is common wherever EPEL gets enabled for "one little package" on a host running a Python application out of a venv. The armor is the same: per-repo `excludepkgs` on day one.

Back to the [README](../README.md)
