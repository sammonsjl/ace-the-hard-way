# Lab 13 — Instance registration

## What you will have at the end

ace-exec registered in AWX as an **execution** instance, in the `default` queue — exactly the queues the real installer creates — and passing a health check over the mesh: the first real signed work unit. (`--node_type=execution` stays as-is: it's the product's literal API value.)

Verified against the bundle's `register_instances.yml` — every command below is the installer's, minus the Ansible wrapping.

## Get the node's UUID (ace-exec)

The installer asks ansible-runner on the execution node for its identity first — the UUID ties the DB record to the machine:

```bash
sudo -u awx /usr/local/bin/ansible-runner worker --worker-info
# note the uuid line — used in the next step
```

## Register the instance (ace-control)

Same `provision_instance` command as Lab 7, different node type, plus the UUID you just collected. The hostname must equal the receptor node ID (`ace-exec`) — that's how the dispatcher addresses work:

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage provision_instance --hostname=ace-exec --node_type=execution --uuid="<UUID_FROM_WORKER_INFO>"'
```

Record the receptor listener address — bookkeeping, not wiring (the actual mesh is the static `receptor.conf` from Lab 12; this row feeds the API and topology view). Exact form from the bundle:

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage add_receptor_address --instance=ace-exec --address=ace-exec --port=27199 --canonical'
```

> The bundle registers **no peer links** in the database on VM installs — mesh topology lives entirely in `receptor.conf`. (DB-managed peering is a Kubernetes-deployment thing.) So: no `register_peers` here.

## The queues (ace-control)

The installer creates exactly two, both by percentage — `controlplane` (Lab 7 made it by hostname; same result on one box) and **`default`**, which is where every work node lands and, critically, **the queue AWX picks automatically for job templates with no instance group set**:

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage register_queue --queuename=default --instance_percent=100'
```

That's why there's no "associate the Demo Job Template" step in this lab anymore: with a `default` queue existing, the demo JT needs nothing. (Custom instance groups are an `instance_group_*` inventory-group feature in the installer — same `register_queue --hostnames=...` command if you ever want one.)

## Health check — the first signed work unit

A health check submits `ansible-runner worker --worker-info` to ace-exec **through the mesh**: signed by the control node, TLS to ace-exec, verified, executed, results streamed back. It's Lab 11 + 12 exercised end to end. Trigger it via the API (set the admin password from Lab 7 first):

```bash
read -s -p "AWX admin password: " AWX_PW; echo

# find the instance id
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/instances/?hostname=ace-exec' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print(r["id"], r["node_state"])'

# trigger the health check (use the id you just got)
curl -sk -u "admin:${AWX_PW}" -X POST \
  https://192.168.56.10/api/v2/instances/<ID>/health_check/ | python3 -m json.tool
```

Give it a few seconds, then confirm the mesh did its job:

```bash
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/instances/?hostname=ace-exec' \
  | python3 -c 'import json,sys; r=json.load(sys.stdin)["results"][0]; print("state:", r["node_state"], " capacity:", r["capacity"], " version:", r["version"])'
# want: state: ready   capacity: > 0   version: ansible-runner's version from ace-exec
```

That `version` string was reported by ansible-runner **on ace-exec** — proof the round trip works. If the state is `unavailable`, the error detail on the instance (and `journalctl -u receptor` on both nodes) says why; the Lab 12 troubleshooting list applies.

## Verify

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage list_instances'
# want two groups:
#   [controlplane]  ace-control  capacity=... node_type=control
#   [default]       ace-exec     capacity=... node_type=execution  version=...
```

Both instances showing capacity means AWX believes it can control on one node and execute on the other. Next lab proves it.

Next: [Smoke test](14-smoke-test.md)
