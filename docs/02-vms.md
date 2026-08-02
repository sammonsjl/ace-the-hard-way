# Lab 2 — The five VMs

## What you will have at the end

Five Rocky Linux 9 VMs that can see and name each other, and all pass the preflight checks.
Nothing component-specific — that starts in Lab 4.

## The topology, and why it has this shape

A real deployment of this platform is not one machine. Its smallest tested distributed shape puts
each component on its own host:

| VM | Address | Runs |
|---|---|---|
| **ace-db** | 192.168.56.10 | PostgreSQL, and nothing else |
| **ace-gateway** | 192.168.56.11 | the platform gateway, Redis, envoy, and the console |
| **ace-controller** | 192.168.56.12 | the automation controller — and, as a **hybrid** node, jobs too |
| **ace-hub** | 192.168.56.13 | automation hub |
| **ace-eda** | 192.168.56.14 | Event-Driven Ansible |

The real shape has a **sixth** VM: a dedicated execution node, with the controller kept
control-only. We fold that role into the controller by making it a **hybrid** node — one that
both schedules work and runs it. That is the single deliberate departure in this tutorial, and it
is worth understanding rather than skipping past:

- A **control** node schedules jobs and hands them to the mesh. It never runs a playbook itself,
  except for control-plane work like project syncs.
- An **execution** node runs jobs and nothing else.
- A **hybrid** node does both.

Splitting them is what lets you scale execution independently of the control plane, and it is why
production deployments do it. Combining them costs you that, saves a VM, and changes nothing else
about how the mesh works — the controller still submits signed work to receptor, receptor still
spawns `ansible-runner`, and jobs still run in containers. The only difference is that the
receptor on the other end of the mesh is the same one that submitted the work.

## Why each component gets its own machine

It is tempting to read this as five times the work. It isn't — it is the *same* work with the
seams made visible, and the seams are the interesting part:

- **Every connection becomes real.** With everything on one box, "the controller talks to the
  database" is a unix socket and a shrug. Here it is a hostname, a port, a firewall rule, and a
  certificate whose SAN has to match. When something breaks, you find out which of those it was.
- **You cannot accidentally share state.** One machine makes it very easy to have the controller
  quietly depend on a file the hub created. Five machines make that impossible.
- **The gateway's job stops being abstract.** Four services on four hosts, one URL, one login.

## Memory

The whole estate has to fit in 16 GB *in total*, so the numbers in the `Vagrantfile` are a lab
compromise:

```
ace-db           1024      postgres alone needs very little
ace-gateway      5120      the console's npm build is the hungriest step in the tutorial
ace-controller   3584      tight — it runs AWX and EE containers
ace-hub          2560
ace-eda          2048
                ------
                14336      leaves ~1.5 GB for the host
```

If your host has more, raise them — nothing in the tutorial depends on these being small. If it
has exactly 16 GB, expect the console build in [Lab 5](05-gateway.md) to lean on swap, which that
lab sets up.

## Bring them up

```bash
vagrant up
vagrant status    # all five running
```

That takes a while on first run — five boxes, five dnf transactions. The Vagrantfile does only
two things beyond booting: it installs `vim curl jq git`, and it writes `/etc/hosts` on every
node.

The `/etc/hosts` part is not laziness. Every node needs every other node's name from
[Lab 3](03-internal-ca.md) onward — certificate SANs, database connection strings, the receptor
mesh — and hand-editing five files five times teaches nothing. It also deletes the box image's own
`127.0.1.1` self-mapping first, which matters more than it looks:

```bash
vagrant ssh ace-controller -c 'getent ahostsv4 ace-db ace-gateway | head -2; grep -c 127.0.1.1 /etc/hosts'
# want: 192.168.56.10 and 192.168.56.11, and a 0
```

> **Why the `127.0.1.1` line has to go.** The bento box maps its own hostname to a loopback
> address. Leave it and `ace-gateway` resolves to `127.0.1.1` *on the gateway itself* — so the
> certificate you sign in Lab 3 carries `IP:127.0.1.1`, and every other machine's TLS connection
> fails a hostname check for reasons that point at the certificate rather than at `/etc/hosts`.
>
> Also note `getent ahostsv4`, not `getent hosts`. On a multi-homed box the latter returns a
> link-local `fe80::` address first, and an `fe80::` in a certificate SAN is worse than no SAN.

## What this lab does NOT do

No service users, no application directories, no packages beyond `vim curl jq git`.

Each component creates its own user and its own filesystem layout in its own lab, on its own
machine — the gateway in [Lab 5](05-gateway.md), the controller in [Lab 6](06-controller.md), hub
in [Lab 8](08-hub.md), EDA in [Lab 9](09-eda.md). That is not tidiness for its own sake: an `awx`
user on the hub node would be a lie about what runs there, and a reader who stops after Lab 5
should have a gateway machine with nothing else pre-seeded on it.

What this lab leaves you is five interchangeable Rocky boxes that can find each other. Everything
that makes a machine *the controller* or *the hub* happens in that component's lab.

## Preflight checks

Each of these is a precondition the rest of the tutorial silently assumes. Run them on **all
five** VMs:

```bash
# 1. Time sync — clock skew breaks TLS handshakes and job timestamps.
#    With five machines and a private CA this matters far more than it did on one.
systemctl is-active chronyd        # want: active
chronyc tracking | head -3         # want: a real reference ID, small offset

# 2. UTF-8 locale — non-UTF-8 breaks Django and postgres init
locale | grep -c 'UTF-8'           # want: > 0, no errors printed

# 3. Hostname is real — receptor refuses 'localhost' node names
hostnamectl hostname               # want: the ace-* name, NOT localhost

# 4. No noexec mounts where code runs — jobs and wheels execute from here
for d in /var /tmp /var/tmp; do
  findmnt -no OPTIONS --target "$d" | grep -q noexec && echo "FAIL: $d is noexec"
done; echo "check done (silence above = OK)"

# 5. Every other node is reachable by name
for h in ace-db ace-gateway ace-controller ace-hub ace-eda; do
  ping -c1 -W2 "$h" >/dev/null && echo "OK   $h" || echo "FAIL $h"
done
```

All five pass on all five nodes = the estate is ready. Any failure = fix it now; every one of
these produces a confusing failure several labs later if ignored.

> Check 5 is new to the distributed build and it is the one that will actually catch something.
> On a single box, name resolution was never exercised. Here, a node that cannot resolve `ace-db`
> fails at database connection time with an error about authentication or timeouts, never about
> DNS.

Next: [The internal CA](03-internal-ca.md)
