# Lab 7 — Database init

## What you will have at the end

A migrated database, an admin user, and this node registered as a **control** instance in the `controlplane` group — the init chain every AWX deployment has to run, done by hand.

Every command runs as `awx` with `AWX_MODE=production` (production mode, `/etc/tower` config, postgres). All on **ace-control**.

## Migrate

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage migrate --noinput'
# want: a long run of "OK" migrations, ending without a traceback
```

## Create the admin user

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage createsuperuser'
# prompts for username (admin), email, and password
```

Scripting this instead (CI, kickstarts)? Django's standard non-interactive form works too:

```bash
sudo -u awx bash -c 'DJANGO_SUPERUSER_PASSWORD=CHANGE-ME AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage createsuperuser --username admin --email admin@example.com --noinput'
```

## Register this node

`ace-control` is a **control** node — it runs the control plane; jobs execute on `ace-exec` (later labs). The `--hostname` must match `CLUSTER_HOST_ID` from Lab 6 (`ace-control`).

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage provision_instance --hostname="$(hostname)" --node_type=control'
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage register_queue --queuename=controlplane --hostnames="$(hostname)"'
```

## Preload data and default EEs

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage create_preload_data'
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage register_default_execution_environments'
```

## Verify

```bash
sudo -u awx bash -c 'AWX_MODE=production /var/lib/awx/venv/awx/bin/awx-manage list_instances'
# want: ace-control listed, type control, in the controlplane group
```

Next: [Running the services](08-awx-services.md)
