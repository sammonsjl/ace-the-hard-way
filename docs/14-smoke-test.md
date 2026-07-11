# Lab 14 — Smoke test — run a job on the execution plane

## What you will have at the end

The whole point: a job launched on your hand-built control plane, dispatched over YOUR receptor mesh, executed in an EE container on the execution plane you built. Labs 1–14 = a complete, working controller.

## First: sync the Demo Project — the control node's sandbox at work

Launching the demo kicks off a **project sync first**, and the sync runs on **ace-control**, not ace-exec. That's not a wiring mistake — SCM updates are control-plane work by definition, and they execute inside the **control-plane EE** under the podman you installed in Lab 11. This sync is its own smoke test: `local` work through receptor, into a container, on the controller.

Watch it happen — on **ace-control**:

```bash
cd /tmp
watch -n1 "sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman ps"
```

In another terminal, trigger the sync:

```bash
read -s -p "AWX admin password: " AWX_PW; echo

curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/projects/?name=Demo%20Project' \
  | python3 -c 'import json,sys; print("project:", json.load(sys.stdin)["results"][0]["id"])'

curl -sk -u "admin:${AWX_PW}" -X POST \
  https://192.168.56.10/api/v2/projects/<PROJECT_ID>/update/ \
  | python3 -c 'import json,sys; print("update job:", json.load(sys.stdin)["id"])'
```

An EE container flashes up in the watch — that's git cloning `ansible-tower-samples` *inside the control-plane EE*. Confirm:

```bash
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/projects/?name=Demo%20Project' \
  | python3 -c 'import json,sys; print(json.load(sys.stdin)["results"][0]["status"])'
# want: successful
```

(The Demo Inventory's `localhost` host with `ansible_connection=local` is exactly right for what's next: "local" means *inside the EE container on ace-exec* — which is the point.)

## Set up the watch posts

**Terminal 1 — ace-exec**, watch for the EE container to appear (`cd /tmp` first — rootless podman can't start from the 0700 vagrant home):

```bash
cd /tmp
watch -n1 "sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman ps"
```

**Terminal 2 — ace-control**, watch the work unit:

```bash
watch -n1 "sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl --socket /var/run/awx-receptor/receptor.sock work list --quiet"
```

**Browser** — `https://192.168.56.10`, logged in, on the Jobs view. The live output you're about to see arrives over the websocket path: daphne, wsrelay, nginx — all yours.

## Launch

**Terminal 3 — ace-control:**

```bash
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/job_templates/?name=Demo%20Job%20Template' \
  | python3 -c 'import json,sys; print("jt:", json.load(sys.stdin)["results"][0]["id"])'

curl -sk -u "admin:${AWX_PW}" -X POST \
  https://192.168.56.10/api/v2/job_templates/<JT_ID>/launch/ \
  | python3 -c 'import json,sys; print("job:", json.load(sys.stdin)["job"])'
```

Watch all three posts at once:

- Terminal 2: a work unit appears, state `Running`
- Terminal 1: a container flashes up running `quay.io/ansible/awx-ee` — that's your job
- Browser: stdout streams live; the debug task prints its hello from a container hostname
- Terminal 2: work unit goes `Succeeded` and is released

Confirm from the API:

```bash
curl -sk -u "admin:${AWX_PW}" https://192.168.56.10/api/v2/jobs/<JOB_ID>/ \
  | python3 -c 'import json,sys; j=json.load(sys.stdin); print(j["status"], "on", j["execution_node"])'
# want: successful on ace-exec
```

## Trace the hops — you built every one

1. **nginx** (Lab 10) accepts the launch POST, hands it to **uwsgi** (Lab 8) over the unix socket
2. The API writes a pending job; the **dispatcher** (Lab 8) picks it up, builds the private data dir from the synced project, and transmits it
3. The dispatcher submits the work unit to **receptor** (Lab 11) over `/var/run/awx-receptor/receptor.sock`, **signed** with the key from Lab 11
4. Receptor carries it over the **TLS mesh** (Lab 12) — mutual certs from your Lab 11 mesh CA, node IDs verified via the receptor OID
5. ace-exec **verifies the signature**, then its work-command runs **ansible-runner worker** (Lab 12)
6. ansible-runner starts the **EE container** under rootless podman — the job sandbox, exactly where the RPM installer puts it
7. Events stream back over the same mesh into the **callback receiver** (Lab 8), into **postgres** (Lab 3), and out through **daphne/wsrelay** (Lab 8) to your browser

That's an automation platform, by hand, from source.

## One more thing that now Just Works

AWX ships default system-job schedules (Cleanup Job Details, Cleanup Activity Stream, ...). System jobs are `local` work — control-plane EE, podman — so with Lab 11's sandbox in place they run on schedule like the bundle intends. Nothing to configure; just know that the weekly cleanup jobs you'll see in the jobs list are these.

> Milestone: **Labs 1–14 are a complete, working controller.** The gateway labs (15–16) add the single-login platform layer on top — and they're the risky tail. Ship this milestone first: commit your notes, tag your fork, take the win.

Next: [The gateway](15-gateway.md)
