# Lab 13 — Instance registration

## What you will have at the end

ace-exec registered in AWX as an **execution** instance, in its own instance group, passing a health check over the mesh — the first real signed work unit — and the demo job template pointed at it. (`--node_type=execution` stays as-is: it's the product's literal API value.)

All commands on **ace-control**.

## Register the instance

Same `provision_instance` command as Lab 7, different node type. The hostname must equal the receptor node ID (`ace-exec`) — that's how the dispatcher addresses work:

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage provision_instance --hostname=ace-exec --node_type=execution'
```

Record the receptor address and the peering link. This is bookkeeping, not wiring — the actual mesh is the static `receptor.conf` from Lab 12; these rows are what feed the API and the topology view:

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage add_receptor_address --instance=ace-exec --address=ace-exec --port=27199 --canonical'
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage register_peers ace-control --peers ace-exec'
```

> These two commands manage database rows only (on Kubernetes, AWX would also rewrite receptor.conf from them — on bare metal it does not). If a flag has drifted on your `devel` checkout, `awx-manage add_receptor_address --help` is the truth; note what changed.

## The instance group

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage register_queue --queuename=bare-metal-exec --hostnames=ace-exec'
```

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

## Point the demo job template at the execution plane

The Demo Job Template has no instance group, and this deployment has no `default` queue — an unassociated job would sit in `pending` forever. Associate it explicitly (raw API POST; the association endpoint takes an object with `id`):

```bash
# find both ids
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/job_templates/?name=Demo%20Job%20Template' \
  | python3 -c 'import json,sys; print("jt:", json.load(sys.stdin)["results"][0]["id"])'
curl -sk -u "admin:${AWX_PW}" \
  'https://192.168.56.10/api/v2/instance_groups/?name=bare-metal-exec' \
  | python3 -c 'import json,sys; print("ig:", json.load(sys.stdin)["results"][0]["id"])'

# associate (fill in both ids)
curl -sk -u "admin:${AWX_PW}" -X POST \
  https://192.168.56.10/api/v2/job_templates/<JT_ID>/instance_groups/ \
  -H 'Content-Type: application/json' -d '{"id": <IG_ID>}'
# want: HTTP 204, no body
```

## Verify

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage list_instances'
# want two groups:
#   [controlplane]     ace-control  capacity=... node_type=control
#   [bare-metal-exec]  ace-exec     capacity=... node_type=execution  version=...
```

Both instances showing capacity means AWX believes it can control on one node and execute on the other. Next lab proves it.

Next: [Smoke test](14-smoke-test.md)
