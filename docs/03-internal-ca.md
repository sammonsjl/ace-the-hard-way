# Lab 3 — The internal CA

## What this is

A private certificate authority for the platform: one root key, kept on one machine, that signs a
TLS certificate for every service you are about to build.

## Where it fits

Four of your five VMs will serve HTTPS, and they all have to trust each other. The gateway proxies
to the controller, hub, and EDA over TLS. The controller fetches a signing key from the gateway
over TLS. Your browser talks to envoy over TLS. That is a lot of certificates, and the question of
who trusts whom has exactly two answers:

- **Self-signed everywhere.** Every service is its own root, so every service needs every other
  service's certificate in its trust store. Four services means twelve trust relationships, and
  reissuing any one of them breaks three others.
- **One CA that signs all of them.** One root goes into the OS trust store on all five nodes. Every
  service validates every other automatically, because they all chain to the same root. Reissue a
  leaf and nothing else changes.

Real deployments do the second, and so do we. It is barely more work — the whole CA is four
commands — and on a five-node estate it is the difference between a build that works and one that
spends its life failing certificate checks.

**This is not the receptor mesh CA.** [Lab 6](06-controller.md) builds a *separate*, dedicated CA
for the execution mesh. That is deliberate: the mesh CA authenticates *nodes* to each other with
mutual TLS on a private port; this CA authenticates *services* to browsers and to each other.
Keeping them apart means a compromised web certificate cannot mint a mesh node, and either can be
rotated without touching the other.

## What you will have at the end

A root CA on **ace-gateway**, its certificate trusted by all five VMs, and a two-part signing
procedure that later labs use to issue each service its certificate — without the CA's private key
ever leaving ace-gateway, and without any service's private key ever leaving the node that owns it.

## Where the CA lives

On **ace-gateway**. It could be any node; the gateway is the natural choice because it is the one
machine every other component already has to trust.

```bash
vagrant ssh ace-gateway
sudo install -d -o root -g root -m 0700 /etc/ansible-automation-platform/ca
```

`0700` and root-owned. The CA private key is the most sensitive file in the entire build: with it,
an attacker mints a certificate for any service and all five nodes trust it. No service user ever
needs to read this directory.

## The root

```bash
sudo openssl genrsa -out /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key 4096
sudo chmod 0400 /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key

sudo openssl req -x509 -new -sha256 -days 3650 \
  -key  /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-key.key \
  -out  /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
  -subj "/C=US/O=ACE/CN=ACE Managed CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign"
```

Three details, all load-bearing:

- **`basicConstraints=critical,CA:TRUE`** is what makes this a CA rather than a server
  certificate. `critical` means a client that doesn't understand the extension must reject the
  certificate rather than ignore it. Without `CA:TRUE`, nothing this key signs will ever validate.
- **`keyUsage=critical,keyCertSign`** says this key signs *certificates* and nothing else. It is
  deliberately not allowed to do TLS server authentication — a root that can also terminate TLS is
  a root someone will eventually deploy onto a web server.
- **No SAN.** Nothing ever connects *to* a CA.

```bash
sudo openssl x509 -in /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
  -noout -text | grep -A1 'Basic Constraints\|Key Usage'
# want: CA:TRUE  and  Certificate Sign
```

## Trust it everywhere

Publish the root certificate through `/vagrant`, which is the repo directory shared into all five
VMs — the courier for anything that has to cross machines in this tutorial:

```bash
# on ace-gateway — the PUBLIC certificate only, never the key:
sudo cp /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt /vagrant/
```

Then on **each of the other four** (`ace-db`, `ace-controller`, `ace-hub`, `ace-eda`):

```bash
sudo cp /vagrant/ansible-automation-platform-managed-ca-cert.crt /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
trust list --filter=ca-anchors | grep -A2 "ACE Managed CA"   # want: a match
```

And on ace-gateway itself, which needs to trust its own root like everyone else:

```bash
sudo cp /etc/ansible-automation-platform/ca/ansible-automation-platform-managed-ca-cert.crt \
        /etc/pki/ca-trust/source/anchors/
sudo update-ca-trust
sudo rm -f /vagrant/ansible-automation-platform-managed-ca-cert.crt
```

> Dropping a file into `anchors/` does nothing on its own — `update-ca-trust` rebuilds the
> extracted bundles that consumers actually read. If a later `openssl verify` fails without an
> explicit `-CAfile`, check
> `grep -c "ACE Managed CA" /etc/pki/ca-trust/extracted/pem/tls-ca-bundle.pem`.

## Signing, in two halves

Here is where a distributed build differs from a single-box one, and it is the whole point of this
section.

**A private key must never leave the machine that will use it.** Not over `/vagrant`, not over
`scp`, not "just this once". So signing is split:

1. On the **node that needs the certificate**: generate a private key and a certificate signing
   request. The key stays there, permanently.
2. Carry the **CSR** — which is public — to ace-gateway.
3. On **ace-gateway**: sign it. The CA key stays there, permanently.
4. Carry the **signed certificate** — also public — back.

Two things move between machines, and both are safe to publish. That is the property worth
building the extra step for.

### On the node that needs a certificate

Install this on **ace-gateway**, **ace-controller**, **ace-hub**, and **ace-eda**:

```bash
sudo vim /usr/local/sbin/ace-request-cert
```

```bash
#!/bin/bash
# ace-request-cert <name> <dir> <group> [ext]
#   name   basename for the pair, e.g. "tower"
#   dir    directory to write them into
#   group  group that owns the pair (the service's own group)
#   ext    certificate extension, default "crt" (some services want "cert")
#
# Generates a private key that never leaves this host, plus a CSR to carry
# to the CA. The SAN covers this node's name and its address.
set -euo pipefail

NAME=$1; DIR=$2; GROUP=$3; EXT=${4:-crt}
HOST=$(hostname -s)
# ahostsv4, not `hosts`: the latter returns a link-local fe80:: address first on
# a multi-homed box, and an fe80:: in a SAN is worse than no SAN at all.
IP=$(getent ahostsv4 "$HOST" | awk '{print $1; exit}')

# only create the directory if it is missing — never re-own one the service already owns
[ -d "$DIR" ] || install -d -o root -g "$GROUP" -m 0750 "$DIR"

openssl genrsa -out "$DIR/$NAME.key" 4096
chown root:"$GROUP" "$DIR/$NAME.key"
chmod 0640 "$DIR/$NAME.key"

openssl req -new -key "$DIR/$NAME.key" -subj "/CN=$HOST" \
  -addext "subjectAltName=DNS:$HOST${IP:+,IP:$IP}" \
  -out "/vagrant/$HOST-$NAME.csr"

echo "wrote /vagrant/$HOST-$NAME.csr — now sign it on ace-gateway:"
echo "  sudo /usr/local/sbin/ace-sign-request $HOST-$NAME $EXT"
echo "then back here:"
echo "  sudo install -o root -g $GROUP -m 0644 /vagrant/$HOST-$NAME.$EXT $DIR/$NAME.$EXT"
```

```bash
sudo chmod 0700 /usr/local/sbin/ace-request-cert
```

### On ace-gateway

```bash
sudo vim /usr/local/sbin/ace-sign-request
```

```bash
#!/bin/bash
# ace-sign-request <basename> [ext]
# Signs /vagrant/<basename>.csr with the platform CA, writing /vagrant/<basename>.<ext>.
set -euo pipefail

REQ=$1; EXT=${2:-crt}
CA=/etc/ansible-automation-platform/ca

# -copy_extensions copy carries the SAN over from the request; the requesting
# node is the only thing that knows its own names.
openssl x509 -req -in "/vagrant/$REQ.csr" -sha256 -days 365 \
  -CA "$CA/ansible-automation-platform-managed-ca-cert.crt" \
  -CAkey "$CA/ansible-automation-platform-managed-ca-key.key" \
  -CAcreateserial \
  -copy_extensions copy \
  -extfile <(printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "keyUsage=keyEncipherment,digitalSignature" \
      "subjectKeyIdentifier=hash" \
      "authorityKeyIdentifier=keyid:always") \
  -out "/vagrant/$REQ.$EXT"

chmod 0644 "/vagrant/$REQ.$EXT"
rm -f "/vagrant/$REQ.csr"
echo "signed /vagrant/$REQ.$EXT"
openssl x509 -in "/vagrant/$REQ.$EXT" -noout -subject -ext subjectAltName
```

```bash
sudo chmod 0700 /usr/local/sbin/ace-sign-request
```

Why each extension is there:

| Extension | Reason |
|---|---|
| `basicConstraints=CA:FALSE` | a leaf must not be able to sign further certificates |
| `keyUsage=keyEncipherment,digitalSignature` | the two things a TLS server key actually does |
| `subjectKeyIdentifier=hash` | gives the certificate a stable fingerprint |
| `authorityKeyIdentifier=keyid:always` | pins which CA key signed it, so validators pick the right root after a rotation |
| `-copy_extensions copy` | carries the **SAN from the request** into the certificate |

That last one is the subtle one. `openssl x509 -req` **discards request extensions by default** — a
deliberate safety measure, since a CSR is attacker-controlled input in the general case. Leave it
out and your certificates come out with a CN and no SAN at all, and every modern client rejects
them with a hostname mismatch that says nothing about SANs. Here the requests are ones we generated
ourselves moments earlier, so copying them is safe.

> **Call both scripts by their full path.** Rocky's `sudo` replaces `PATH` with a `secure_path` of
> `/sbin:/bin:/usr/sbin:/usr/bin` — no `/usr/local` anywhere
> (`sudo grep secure_path /etc/sudoers`). `sudo ace-sign-request …` gives you `command not found`
> while the file sits there, executable, one directory over.

## Verify

Do a full round trip from a node that is *not* the CA. On **ace-controller**:

```bash
sudo /usr/local/sbin/ace-request-cert smoketest /tmp/ca-smoketest root
```

On **ace-gateway**:

```bash
sudo /usr/local/sbin/ace-sign-request ace-controller-smoketest
# want: subject=CN=ace-controller, SAN with DNS:ace-controller, IP:192.168.56.12
```

Back on **ace-controller**:

```bash
sudo install -o root -g root -m 0644 /vagrant/ace-controller-smoketest.crt /tmp/ca-smoketest/smoketest.crt
sudo openssl verify /tmp/ca-smoketest/smoketest.crt
# want: OK — and note there is no -CAfile: it resolved through the system trust store

sudo rm -rf /tmp/ca-smoketest /vagrant/ace-controller-smoketest.crt
```

That single `openssl verify` proves three things at once: the CA signed it, the trust store on a
*different* machine accepts it, and the SAN survived the trip.

## What later labs will do with this

| Lab | Node | Certificate |
|---|---|---|
| [5 — the gateway](05-gateway.md) | ace-gateway | `gateway.cert` in `/etc/ansible-automation-platform/gateway` |
| [6 — the controller](06-controller.md) | ace-controller | `tower.cert` in `/etc/tower` |
| [7 — hub](08-hub.md) | ace-hub | `pulp_webserver.crt` |
| [8 — EDA](09-eda.md) | ace-eda | `server.cert` |

Note the inconsistent extensions — `.cert` for some, `.crt` for others. That is not a typo here;
the services genuinely disagree about what to call a certificate and their configuration files
expect specific names, which is why both scripts take the extension as an argument.

Next: [PostgreSQL](04-postgresql.md)
