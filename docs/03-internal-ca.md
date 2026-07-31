# Lab 3 — The internal CA

## What you will have at the end

A private certificate authority on **ace-control**, its root certificate trusted by both VMs,
and a repeatable signing procedure that every service in the rest of the build will use for
its TLS certificate.

Nothing listens yet. This lab produces key material and one trusted root — but it comes third,
before a single service exists, because everything built after it wants a certificate signed
by this CA, and retrofitting a CA under running services is miserable.

## Why one CA and not six self-signed certs

You are about to stand up four HTTPS services — the gateway, the controller, hub, and EDA —
plus a proxy in front of them. Each needs a certificate. There are two ways to do that:

- **Six self-signed certs.** Every service is its own root. A browser objects six times. Worse,
  the services have to talk to *each other* over HTTPS — the controller validates a JWT by
  fetching a key from the gateway, the proxy connects to each backend — so every service needs
  every other service's cert in its trust store. That's a mesh of trust relationships that grows
  quadratically and breaks the first time you reissue anything.
- **One CA that signs all of them.** One root goes into the OS trust store on both nodes. Every
  service validates every other service automatically, because they all chain to the same root.
  Reissue a leaf and nothing else has to change.

The second is what a real platform install does, and it is barely more work. The whole CA is
four commands.

> **This is not the receptor mesh CA.** [Lab 13](13-receptor.md) builds a *separate*, dedicated
> CA for the execution mesh. That is deliberate, not an oversight: the mesh CA authenticates
> *nodes* to each other with mutual TLS and client certificates, on a private port, with its own
> lifecycle. This CA authenticates *services* to browsers and to each other. Keeping them apart
> means a compromised web certificate can't mint a mesh node, and you can rotate one without
> touching the other. Two CAs, two jobs.

All commands on **ace-control** unless a step says otherwise.

## Create the CA directory

```bash
sudo install -d -o root -g root -m 0700 /etc/ansible-automation-platform/ca
```

`0700` and root-owned. The CA private key is the most sensitive file in the entire build — with
it, an attacker mints a certificate for any service and every node trusts it. No service user
ever needs to read this directory; services only ever get handed their own leaf key.

## Generate the root key

```bash
sudo openssl genrsa -out /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key 4096
sudo chmod 0400 /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key
```

4096 bits for the root. Leaf certificates get reissued yearly; a root sticks around for a decade,
so it gets the bigger key.

## Self-sign the root certificate

```bash
sudo openssl req -x509 -new -sha256 -days 3650 \
  -key  /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key \
  -out  /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
  -subj "/C=US/O=ACE/CN=ACE Managed CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign"
```

Three details matter, and all three are load-bearing:

- **`basicConstraints=critical,CA:TRUE`** is what makes this a CA rather than a server
  certificate. `critical` means a client that doesn't understand the extension must reject the
  cert rather than ignore it. Without `CA:TRUE`, nothing this key signs will ever validate.
- **`keyUsage=critical,keyCertSign`** says this key signs *certificates* and nothing else. It is
  deliberately not allowed to do TLS server authentication. A root that can also terminate TLS is
  a root you'll eventually be tempted to deploy onto a web server.
- **No SAN.** A CA certificate has no subject alternative names, because nothing ever connects
  *to* it. `openssl req -x509` won't add one unless you ask; other tooling sometimes copies the
  CN into a SAN by default, which is harmless but meaningless here.

Check what you built:

```bash
sudo openssl x509 -in /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
  -noout -text | grep -A1 'Basic Constraints\|Key Usage'
# want: CA:TRUE  and  Certificate Sign
```

## Trust it on both nodes

A certificate is only useful if the machines validating it know the root. Rocky's trust store
takes files dropped into an anchors directory, then rebuilds its bundles:

```bash
sudo cp /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
        /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

Now the same on **ace-exec**. The repo is shared into both VMs at `/vagrant`, which is the
courier — the same trick [Lab 14](14-execution-plane.md) uses for mesh certificates:

```bash
# on ace-control — hand the PUBLIC cert across (never the key):
sudo cp /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt /vagrant/
```

```bash
# on ace-exec:
sudo cp /vagrant/ansible-automation-platform-managed-ca-cert.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
```

```bash
# back on ace-control — don't leave it lying in the repo:
sudo rm -f /vagrant/ansible-automation-platform-managed-ca-cert.crt
```

> `/vagrant` **is** the repo directory on your laptop. Anything you copy there appears in
> `git status`. The root certificate is public and harmless, but building the habit now matters
> — Lab 14 moves mesh *private keys* through the same channel, and the `.gitignore` that catches
> them is a safety net, not a plan.

## The signing procedure

Five later labs need a certificate. Rather than repeat eight lines of `openssl` each time, write
the procedure down once as a script. It takes a service name, a certificate directory, an owning
group, and the hostname to put in the SAN.

```bash
sudo vim /usr/local/sbin/ace-sign-service
```

```bash
#!/bin/bash
# ace-sign-service <name> <dir> <group> <hostname> [ext]
#   name     basename for the key/cert pair, e.g. "gateway"
#   dir      directory to write them into
#   group    group that owns the pair (the service's own group)
#   hostname DNS name the service is reached by
#   ext      certificate extension, default "crt" (some services want "cert")
set -euo pipefail

NAME=$1; DIR=$2; GROUP=$3; HOST=$4; EXT=${5:-crt}
CA=/etc/ansible-automation-platform/ca
# ahostsv4, not `hosts`: plain `getent hosts` returns link-local IPv6 first on a
# multi-homed box, and an fe80:: address in a SAN is worse than no SAN at all.
IP=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')

install -d -o root -g "$GROUP" -m 0750 "$DIR"

openssl genrsa -out "$DIR/$NAME.key" 4096
chown root:"$GROUP" "$DIR/$NAME.key"
chmod 0640 "$DIR/$NAME.key"

openssl req -new -key "$DIR/$NAME.key" -subj "/CN=$HOST" -out "/tmp/$NAME.csr"

openssl x509 -req -in "/tmp/$NAME.csr" -sha256 -days 365 \
  -CA "$CA/ansible-automation-platform-managed-ca-cert.crt" \
  -CAkey "$CA/ansible-automation-platform-managed-ca-key.key" \
  -CAcreateserial \
  -extfile <(printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "keyUsage=keyEncipherment,digitalSignature" \
      "subjectKeyIdentifier=hash" \
      "authorityKeyIdentifier=keyid:always" \
      "subjectAltName=DNS:$HOST${IP:+,IP:$IP}") \
  -out "$DIR/$NAME.$EXT"

chown root:"$GROUP" "$DIR/$NAME.$EXT"
chmod 0644 "$DIR/$NAME.$EXT"
rm -f "/tmp/$NAME.csr"

echo "signed $DIR/$NAME.$EXT"
openssl x509 -in "$DIR/$NAME.$EXT" -noout -subject -ext subjectAltName
```

```bash
sudo chmod 0700 /usr/local/sbin/ace-sign-service
```

> **Call it by its full path.** Rocky's `sudo` resets `PATH` to a `secure_path` that does **not**
> include `/usr/local/sbin` or `/usr/local/bin` — check yours with
> `sudo grep secure_path /etc/sudoers`. So `sudo ace-sign-service …` gives you
> `sudo: ace-sign-service: command not found` even though the file is right there and executable.
> Every invocation in this tutorial spells the path out.

Why each extension is there:

| Extension | Reason |
|---|---|
| `basicConstraints=CA:FALSE` | a leaf must not be able to sign further certificates |
| `keyUsage=keyEncipherment,digitalSignature` | the two things a TLS server key actually does |
| `subjectKeyIdentifier=hash` | gives the cert a stable fingerprint |
| `authorityKeyIdentifier=keyid:always` | pins which CA key signed it, so validators pick the right root even after a rotation |
| `subjectAltName` | **the only field modern clients check.** A CN alone gets you a hostname-mismatch error in every browser released since about 2017 |

The private key is `0640 root:<group>` — readable by the service, writable by nobody but root.
The certificate is `0644`; it's public.

`-days 365` matches what a real install issues. Certificates that outlive their service are how
you end up with a ten-year key nobody remembers generating.

## Verify

Sign a throwaway certificate and confirm it chains:

```bash
sudo /usr/local/sbin/ace-sign-service smoketest /tmp/ca-smoketest root ace-control
sudo openssl verify \
  -CAfile /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
  /tmp/ca-smoketest/smoketest.crt
# want: /tmp/ca-smoketest/smoketest.crt: OK
```

And confirm the OS trust store — not just an explicit `-CAfile` — accepts it. This is the check
that proves `update-ca-trust` worked:

```bash
sudo openssl verify /tmp/ca-smoketest/smoketest.crt
# want: OK   (no -CAfile: it resolved through the system trust store)

sudo rm -rf /tmp/ca-smoketest
```

Do the same trust check on **ace-exec** using the cert you already copied:

```bash
# on ace-exec:
trust list --filter=ca-anchors | grep -i "ACE Managed CA"
# want: a match — the anchor is installed
```

> **If `openssl verify` fails without `-CAfile`,** `update-ca-trust` didn't run or didn't take.
> Re-run it and check `/etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` contains your CN:
> `grep -c "ACE Managed CA" /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem` — anything above
> zero is fine. Dropping a file into `anchors/` does nothing on its own; the extracted bundles
> are what consumers actually read.

## What later labs will do with this

| Lab | Signs | Path |
|---|---|---|
| [6 — the gateway](06-gateway.md) | `gateway` | `/etc/ansible-automation-platform/gateway/gateway.cert` |
| [12 — nginx](12-nginx.md) | `tower` | `/etc/tower/tower.cert` |
| [18 — hub](18-hub.md) | `pulp_webserver` | hub's config directory |
| [19 — EDA](19-eda.md) | `server` | `/etc/ansible-automation-platform/eda/server.cert` |

Note the inconsistent extensions — `.cert` for some services, `.crt` for others. That is not a
typo in this tutorial; the services genuinely disagree with each other about what to call a
certificate, and their config files expect specific names. The script takes the extension as an
argument for exactly this reason.

Next: [PostgreSQL](04-postgresql.md)
