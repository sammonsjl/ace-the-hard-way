# Lab 17 — Smoke test — run a job on the execution plane

## What you will have at the end

The whole point: a job launched **from the platform console you built**, authorised by your gateway, dispatched over your receptor mesh, and executed in an EE container on the execution plane you built. Every hop hand-made.

This lab is deliberately click-driven. Everything up to now has been command line; the test of a platform is whether a person can use it. Every button press below travels through envoy → the gateway's gRPC authorisation → nginx → uwsgi → the dispatcher → receptor → podman, and the live output comes back through daphne and wsrelay — all yours.

## Log in

Open **`https://192.168.56.10`** and log in as `admin` — the **gateway** admin from Lab 6, not the controller's own admin from Lab 10. Since [Lab 16](16-service-registration.md) the controller only accepts gateway-issued JWTs, so the platform account is the only one that works.

> No certificate warning, if you imported [Lab 3](03-internal-ca.md)'s root CA into your browser. If you didn't, accept the interstitial — the CA is at
> `/etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt`.

## Sync the Demo Project

In the left-hand navigation: **Automation Execution → Projects → Demo Project**, then click the **sync** button (the circular-arrows icon on the project's row or its detail page).

> That whole navigation section only exists because Lab 16 registered the controller. If you don't see **Automation Execution**, the registry row is missing or envoy hasn't picked it up yet — give it five seconds and reload before debugging anything else.

Watch the status go `Pending → Running → Successful`, live — no page refresh. That live update is your websocket stack working.

**What just happened, and where:** the sync ran on **ace-control**, not ace-exec. That's not a wiring mistake — SCM updates are control-plane work by definition, so they execute in the **control-plane EE** under the podman from Lab 13. You already proved this path in [Lab 13's local-work check](13-receptor.md#prove-local-work-actually-runs); this time you did it as a user, and the job about to run needs the project on disk.

(The Demo Inventory's `localhost` host with `ansible_connection=local` is exactly right for what's next: "local" means *inside the EE container on ace-exec* — which is the point.)

## Launch the Demo Job Template

`Resources → Templates → Demo Job Template`, then **Launch**.

The job's output view opens and stdout streams in line by line. That stream is not polling — it's the websocket path (daphne, wsrelay, nginx), and the events reaching it came back over the receptor mesh from another machine.

Expect: the `Hello World!` debug task, then `PLAY RECAP` with `ok=2 changed=1 failed=0`, and a green **Successful**.

## Confirm it ran on the execution plane

This is the assertion that matters — the job must not have run on the controller. On the job's **Details** tab, check:

- **Execution Node** — `ace-exec`
- **Execution Environment** — the default EE
- **Instance Group** — the group Lab 15 registered

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

1. **nginx** (Lab 12) accepts the launch request, hands it to **uwsgi** (Lab 11) over the unix socket
2. The API writes a pending job; the **dispatcher** (Lab 11) picks it up, builds the private data dir from the synced project, and transmits it
3. The dispatcher submits the work unit to **receptor** (Lab 13) over `/var/run/awx-receptor/receptor.sock`, **signed** with the key from Lab 13
4. Receptor carries it over the **TLS mesh** (Lab 14) — mutual certs from your Lab 13 mesh CA, node IDs verified via the receptor OID
5. ace-exec **verifies the signature**, then its work-command runs **ansible-runner worker** (Lab 14)
6. ansible-runner starts the **EE container** under rootless podman — the job sandbox, and the only container in the whole picture
7. Events stream back over the same mesh into the **callback receiver** (Lab 11), into **postgres** (Lab 4), and out through **daphne/wsrelay** (Lab 11) to your browser

That's an automation platform, by hand, from source.

## If it doesn't go green

| What you see | Where to look |
|---|---|
| Stuck in `Pending`, nothing on either node | Task manager isn't scheduling — the `devonly`/`AWX_MODE` pair ([Lab 8](08-awx-source.md), Lab 11) |
| `Running` forever, no container on ace-exec | Mesh — check `receptorctl status` on both nodes; peer, firewalld `27199`, node-ID SAN, clock skew ([Lab 14](14-execution-plane.md)) |
| Fails instantly, empty `result_traceback` | EE can't start: linger, or exit 132 on Apple Silicon ([Lab 13](13-receptor.md)) |
| `Execution Node: ace-control` | Instance/queue registration — the job never left the control plane ([Lab 15](15-instance-registration.md)) |

## One more thing that now Just Works

AWX ships default system-job schedules (Cleanup Job Details, Cleanup Activity Stream, ...). System jobs are `local` work — control-plane EE, podman — so with Lab 13's sandbox in place they run on schedule, unprompted. Nothing to configure; just know that the weekly cleanup jobs you'll see in the jobs list are these.

> Milestone: **Labs 1–17 are a complete, working platform** — gateway, console, controller, and a two-node execution mesh, all from source. Labs 18–19 add hub and EDA, which join in exactly the same way and are strictly additive. Ship this milestone first: commit your notes, tag your fork, take the win.

Next: [Automation Hub](18-hub.md)
