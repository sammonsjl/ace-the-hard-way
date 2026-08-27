# Lab 4 — PostgreSQL and Redis

> **Not written yet.** Goal and outline below; unchecked boxes are undone. The labs are written as they are performed for the first time.

## What you will have at the end

One PostgreSQL container serving four databases to four services, one Redis container, and the first two quadlets you write that matter — plus the run pattern every later lab repeats.

## Where it fits

This is the easy case, on purpose. Neither of these images is built from source: PostgreSQL and Redis are upstream images configured by files you mount, because building a database from source to learn about automation platforms is a detour with no destination.

That makes this the right place to learn the **run** pattern with nothing else going wrong — mounts, secrets, quadlets, user namespaces, dependency ordering. [Lab 5](05-gateway.md) introduces the **build** pattern on top of it, and by then the run half should be boring.

## Outline

- [ ] `~/ace/postgresql/` and `~/ace/redis/`, config written by hand
- [ ] `postgres:15` — the version the bundle pins, and why not `:latest`
- [ ] Four roles and four databases: `awx`, `gateway`, `pulp`, `eda`
- [ ] `scram-sha-256`, and where the passwords come from
- [ ] **podman secrets** rather than environment variables — what `podman secret create` actually stores, and where
- [ ] The postgres quadlet, on 5432
- [ ] **`userns: keep-id` and why postgres is the exception.** Every other container in this tutorial maps the container user to your UID; the official postgres image has its own uid-999 machinery that wants the default rootless namespace instead. Getting this wrong produces a permission error on the data directory that looks like a volume problem and is not
- [ ] The trust-bundle mount from [Lab 3](03-internal-ca.md), which every container carries from here on
- [ ] Redis on 6379, plus the unix socket the gateway uses — one Redis, six logical databases, and who holds which
- [ ] `Requires=`/`After=` ordering so the services that need a database wait for one
- [ ] Verify: connect to each database as its own role, from inside a container and from the host

## Open questions

- The bundle runs Redis with TLS and a password on the network port, and a plain unix socket for the gateway. On one host, is the TLS half worth keeping for the lesson or is it noise?
- Where the four passwords are generated and how they reach [Lab 5](05-gateway.md) onward without being retyped.

Next: [The platform gateway](05-gateway.md)
