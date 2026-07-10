# Lab 13 — Instance registration

## What you will have at the end

The execution plane registered in AWX and ready to receive work. (`--node_type=execution` stays as-is — it's the product's literal API value.)

## Outline (to be written)

- [ ] Register the instance: `awx-manage provision_instance --hostname=ace-exec --node_type=execution`
- [ ] Add the receptor address + peering (`awx-manage add_receptor_address` / peers from control)
- [ ] Instance group `bare-metal-exec` containing ace-exec
- [ ] Health check: instance shows capacity in the API (`/api/v2/instances/`)
- [ ] Associate the demo job template with the instance group (raw API POST — awxkit's `associate` lacks the flag)

Next: [Smoke test](14-smoke-test.md)
