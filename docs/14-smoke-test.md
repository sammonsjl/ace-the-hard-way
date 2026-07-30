# Lab 14 — Smoke test — run a job on the execution plane

## What you will have at the end

The whole point: a job launched **from the web UI you built**, dispatched over YOUR receptor mesh, executed in an EE container on the execution plane you built. Labs 1–14 = a complete, working controller.

This lab is deliberately click-driven. Everything up to now has been command line; the test of a platform is whether a person can use it. Every button press below travels through nginx → uwsgi → the dispatcher → receptor → podman, and the live output comes back through daphne and wsrelay — all yours.

## Log in

Open **`https://192.168.56.10`** and log in as `admin` with the password from Lab 7.

> Accept the browser warning about the self-signed cert from Lab 10 — that's expected. If the login page renders but the login *does nothing*, and you've already done Lab 16, that's the `RESOURCE_SERVER` JWT lockout described there, not a broken password.

## Sync the Demo Project

`Resources → Projects → Demo Project`, then click the **sync** button (the circular-arrows icon on the project's row or its detail page).

Watch the status go `Pending → Running → Successful`, live — no page refresh. That live update is your websocket stack working.

**What just happened, and where:** the sync ran on **ace-control**, not ace-exec. That's not a wiring mistake — SCM updates are control-plane work by definition, so they execute in the **control-plane EE** under the podman from Lab 11. You already proved this path in [Lab 11's local-work check](11-receptor.md#prove-local-work-actually-runs); this time you did it as a user, and the job about to run needs the project on disk.

(The Demo Inventory's `localhost` host with `ansible_connection=local` is exactly right for what's next: "local" means *inside the EE container on ace-exec* — which is the point.)

## Launch the Demo Job Template

`Resources → Templates → Demo Job Template`, then **Launch**.

The job's output view opens and stdout streams in line by line. That stream is not polling — it's the websocket path (daphne, wsrelay, nginx), and the events reaching it came back over the receptor mesh from another machine.

Expect: the `Hello World!` debug task, then `PLAY RECAP` with `ok=2 changed=1 failed=0`, and a green **Successful**.

## Confirm it ran on the execution plane

This is the assertion that matters — the job must not have run on the controller. On the job's **Details** tab, check:

- **Execution Node** — `ace-exec`
- **Execution Environment** — the default EE
- **Instance Group** — the group Lab 13 registered

`Execution Node: ace-exec` is the proof: your control plane handed real work across a TLS mesh you built to a machine that has no database, no redis, and no credentials of its own.

## Optional — watch the machinery while it runs

Skip this if you just want the win. But the labs exist to make the invisible visible, so it's worth launching the job a second time with these two running.

**On ace-exec** — the EE container appearing and exiting (`cd /tmp` first; rootless podman can't start from the 0700 vagrant home):

```bash
cd /tmp
watch -n1 "sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman ps"
```

**On ace-control** — the work unit's lifecycle:

```bash
watch -n1 "sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl --socket /var/run/awx-receptor/receptor.sock work list --quiet"
```

Hit Launch again and watch all three surfaces at once: a work unit appears and goes `Running`, a container flashes up running `quay.io/ansible/awx-ee` on ace-exec, stdout streams in the browser, then the work unit goes `Succeeded` and is released.

## Trace the hops — you built every one

1. **nginx** (Lab 10) accepts the launch request, hands it to **uwsgi** (Lab 8) over the unix socket
2. The API writes a pending job; the **dispatcher** (Lab 8) picks it up, builds the private data dir from the synced project, and transmits it
3. The dispatcher submits the work unit to **receptor** (Lab 11) over `/var/run/awx-receptor/receptor.sock`, **signed** with the key from Lab 11
4. Receptor carries it over the **TLS mesh** (Lab 12) — mutual certs from your Lab 11 mesh CA, node IDs verified via the receptor OID
5. ace-exec **verifies the signature**, then its work-command runs **ansible-runner worker** (Lab 12)
6. ansible-runner starts the **EE container** under rootless podman — the job sandbox, and the only container in the whole picture
7. Events stream back over the same mesh into the **callback receiver** (Lab 8), into **postgres** (Lab 3), and out through **daphne/wsrelay** (Lab 8) to your browser

That's an automation platform, by hand, from source.

## If it doesn't go green

| What you see | Where to look |
|---|---|
| Stuck in `Pending`, nothing on either node | Task manager isn't scheduling — the `devonly`/`AWX_MODE` pair ([Lab 5](05-awx-source.md), Lab 8) |
| `Running` forever, no container on ace-exec | Mesh — check `receptorctl status` on both nodes; peer, firewalld `27199`, node-ID SAN, clock skew ([Lab 12](12-execution-plane.md)) |
| Fails instantly, empty `result_traceback` | EE can't start: linger, or exit 132 on Apple Silicon ([Lab 11](11-receptor.md)) |
| `Execution Node: ace-control` | Instance/queue registration — the job never left the control plane ([Lab 13](13-instance-registration.md)) |

## One more thing that now Just Works

AWX ships default system-job schedules (Cleanup Job Details, Cleanup Activity Stream, ...). System jobs are `local` work — control-plane EE, podman — so with Lab 11's sandbox in place they run on schedule, unprompted. Nothing to configure; just know that the weekly cleanup jobs you'll see in the jobs list are these.

> Milestone: **Labs 1–14 are a complete, working controller.** The gateway labs (15–16) add the single-login platform layer on top — and they're the risky tail. Ship this milestone first: commit your notes, tag your fork, take the win.

Next: [The gateway](15-gateway.md)
