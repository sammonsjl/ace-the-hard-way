# Lab 14 — Smoke test — run a job on the execution plane

## What you will have at the end

The whole point: a job launched on your hand-built control plane, dispatched over YOUR receptor mesh, executed in an EE container on the execution plane you built. Labs 1–14 = a complete, working controller.

## First: make the demo runnable on a bare-metal control plane

One honest limitation to deal with (flagged in Lab 11). The Demo Project is an **SCM project** — git type. Syncing it is control-plane work, and on a real AAP control node that sync runs inside a control-plane EE under podman. This control plane is bare metal by design: no podman, so no SCM syncs. The pattern that sidesteps it — and a classic Tower pattern in its own right — is a **manual project**: playbooks placed directly in `PROJECTS_ROOT`, no sync needed. The job payload is transmitted to ace-exec by the dispatcher itself (in-process, no container), so nothing else changes.

On **ace-control**, create the project dir and write the playbook by hand — it keeps the name `hello.yml`, so the Demo Job Template needs no change:

```bash
sudo -u awx install -d /var/lib/awx/projects/ace-demo
sudo -u awx tee /var/lib/awx/projects/ace-demo/hello.yml >/dev/null <<'EOF'
---
- name: ACE smoke test
  hosts: all
  gather_facts: false
  tasks:
    - name: where am I actually running?
      ansible.builtin.command: uname -n
      register: node

    - name: say hello
      ansible.builtin.debug:
        msg: "Hello from {{ node.stdout }} — an EE container on the execution plane."
EOF
```

Flip the Demo Project from git to manual (empty `scm_type` = manual; `local_path` = the dir above):

```bash
read -s -p "AWX admin password: " AWX_PW; echo

curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/projects/?name=Demo%20Project' \
  | python3 -c 'import json,sys; print("project:", json.load(sys.stdin)["results"][0]["id"])'

curl -sk -u "admin:${AWX_PW}" -X PATCH \
  https://192.168.56.10/api/v2/projects/<PROJECT_ID>/ \
  -H 'Content-Type: application/json' \
  -d '{"scm_type": "", "local_path": "ace-demo"}' | python3 -m json.tool | grep -E 'scm_type|local_path'
# want: "scm_type": "", "local_path": "ace-demo"
```

(The Demo Inventory's `localhost` host with `ansible_connection=local` is exactly right here: "local" means *inside the EE container on ace-exec* — which is the point.)

## Set up the watch posts

**Terminal 1 — ace-exec**, watch for the EE container to appear:

```bash
watch -n1 "sudo -u awx XDG_RUNTIME_DIR=/run/user/$(id -u awx) podman ps"
```

**Terminal 2 — ace-control**, watch the work unit:

```bash
watch -n1 "sudo -u awx /var/lib/awx/venv/awx/bin/receptorctl --socket /var/run/receptor/receptor.sock work list --quiet"
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
2. The API writes a pending job; the **dispatcher** (Lab 8) picks it up, builds the private data dir from your manual project (Lab 14), and transmits it — in-process, no container
3. The dispatcher submits the work unit to **receptor** (Lab 11) over `/var/run/receptor/receptor.sock`, **signed** with the key from Lab 11
4. Receptor carries it over the **TLS mesh** (Lab 12) — mutual certs from your Lab 10 CA, node IDs verified via the receptor OID
5. ace-exec **verifies the signature**, then its work-command runs **ansible-runner worker** (Lab 12)
6. ansible-runner starts the **EE container** under rootless podman — the only container in the whole build, and it exists because EEs are containers by definition
7. Events stream back over the same mesh into the **callback receiver** (Lab 8), into **postgres** (Lab 3), and out through **daphne/wsrelay** (Lab 8) to your browser

That's an automation platform, by hand, from source.

## Loose end: the cleanup schedules

AWX ships default system-job schedules (Cleanup Job Details, Cleanup Activity Stream, ...). System jobs are `local` work — control-plane EE, podman — so **on this build they will fail on schedule**, loudly, in the jobs list. Three honest options:

1. **Leave them failing** — harmless noise, and a permanent reminder of the trade you made
2. **Disable the schedules** and prune by hand when needed (`awx-manage cleanup_jobs --days=90` runs natively — it's a manage command, not a system job):

```bash
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/schedules/?unified_job_template__job_type=cleanup_jobs' \
  | python3 -m json.tool | grep -E '"id"|"name"'
# then, per schedule id:
curl -sk -u "admin:${AWX_PW}" -X PATCH \
  https://192.168.56.10/api/v2/schedules/<ID>/ \
  -H 'Content-Type: application/json' -d '{"enabled": false}'
```

3. **The production answer:** put podman on the control node (that's what real AAP does). If you ever want SCM projects on this build, that's the door — it just stops being the pure bare-metal statement this tutorial makes.

> Milestone: **Labs 1–14 are a complete, working controller.** The gateway labs (15–16) add the single-login platform layer on top — and they're the risky tail. Ship this milestone first: commit your notes, tag your fork, take the win.

Next: [The gateway](15-gateway.md)
