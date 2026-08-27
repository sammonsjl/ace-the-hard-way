# Lab 3 — The internal CA

## What this is

A private certificate authority for the platform: one root key that signs a TLS certificate for every service you are about to build — and a trust store that every container will carry, built once, on the host, before any of those containers exist.

## Where it fits

Four of your services will serve HTTPS, and they all have to trust each other. The gateway proxies to the controller, hub, and EDA over TLS. The controller fetches a signing key from the gateway over TLS. Your browser talks to envoy over TLS. That is a lot of certificates, and the question of who trusts whom has exactly two answers:

- **Self-signed everywhere.** Every service is its own root, so every service needs every other service's certificate in its trust store. Four services means twelve trust relationships, and reissuing any one of them breaks three others.
- **One CA that signs all of them.** One root goes into the trust store every container shares. Every service validates every other automatically, because they all chain to the same root. Reissue a leaf and nothing else changes.

Real deployments do the second, and so do we.

Running on one host changes *where* this happens but not *whether* it matters. Envoy still validates the gateway's certificate. The controller still validates the gateway's. The names still have to match — which is why you put `ace-gateway` and friends in `/etc/hosts` in [Lab 2](02-host.md) instead of writing `127.0.0.1` everywhere. A certificate is issued to a name, and a platform whose every name is `localhost` teaches you nothing about the mechanism that will break in production.

**This CA does not authenticate receptor nodes to each other.** A multi-node receptor mesh secures node-to-node traffic with mutual TLS on a private port, and a real distributed build would give that its own dedicated CA — kept separate on purpose, so a compromised web certificate could never mint a mesh node. This tutorial runs a single node, so there is no node-to-node traffic and no mesh CA ([Lab 7](07-execution.md) explains why). This CA's only job is to authenticate *services* — to browsers and to each other.

## What you will have at the end

A root CA under `~/ace/tls/`, an extracted trust bundle that every container will mount, and a signing procedure the later labs use to issue each service its certificate.

## Where the CA lives

```bash
install -d -m 0700 ~/ace/tls
```

`0700`, owned by you, and **not root**. Nothing on this track runs as root on the host; the CA is a set of files in your home directory, protected by your own account. With the private key an attacker mints a certificate for any service in the platform and every container trusts it, so it gets the tightest mode a file can have and it never goes anywhere.

**It also never goes into an image.** That is this track's version of the bare-metal rule that a private key never leaves the machine that owns it. Anything baked into a Containerfile is in a layer, and a layer is a thing you can push, pull, and unpack. Every key in this tutorial is *mounted* at run time, never `COPY`'d at build time — and when you write your first Containerfile in [Lab 5](05-gateway.md), that is the rule you are following.

## The root

```bash
openssl genrsa -out ~/ace/tls/ca.key 4096
chmod 0400 ~/ace/tls/ca.key

openssl req -x509 -new -sha256 -days 3650 \
  -key  ~/ace/tls/ca.key \
  -out  ~/ace/tls/ca.cert \
  -subj "/C=US/O=ACE/CN=ACE Managed CA" \
  -addext "basicConstraints=critical,CA:TRUE" \
  -addext "keyUsage=critical,keyCertSign"
```

Three details, all load-bearing:

- **`basicConstraints=critical,CA:TRUE`** is what makes this a CA rather than a server certificate. `critical` means a client that doesn't understand the extension must reject the certificate rather than ignore it. Without `CA:TRUE`, nothing this key signs will ever validate.
- **`keyUsage=critical,keyCertSign`** says this key signs *certificates* and nothing else. It is deliberately not allowed to do TLS server authentication — a root that can also terminate TLS is a root someone will eventually deploy onto a web server.
- **No SAN.** Nothing ever connects *to* a CA.

```bash
openssl x509 -in ~/ace/tls/ca.cert -noout -text | grep -A1 'Basic Constraints\|Key Usage'
```

> **The file is `ca.cert`, not `ca.crt`.** That is the name the vendor's containerized installer uses, and the labs that follow mount it by that name. Extensions in this tutorial are inconsistent because the *services* are inconsistent about them — see the note at the end of this lab.

## Trust it everywhere

Here is the part with no bare-metal equivalent.

On a VM you drop a certificate into `/etc/pki/ca-trust/source/anchors/`, run `update-ca-trust`, and every program on the box picks it up. You cannot do that here. Your services live in images that were built on a different machine, at a different time, by someone who had never heard of your CA — and you are not going to rebuild nine images every time you reissue a root.

So the trust store gets built **once, on the host**, and mounted into every container.

`update-ca-trust` does two things: it reads the anchors directory, and it writes the *extracted* bundles that programs actually consult — `tls-ca-bundle.pem` for OpenSSL, a Java keystore, and so on. Those extracted files are just files. Build them once, and every container can share them.

Make the directories the extractor expects:

```bash
mkdir -p ~/ace/tls/extracted/{edk2,java,pem,openssl}
```

Now run `update-ca-trust` — not on your host, which has its own trust store you should not be touching, but inside a throwaway EL9 container that exists for one command and then removes itself:

```bash
podman run --rm --user root --entrypoint "" \
  -v ~/ace/tls/extracted:/etc/pki/ca-trust/extracted:z \
  -v ~/ace/tls/ca.cert:/etc/pki/ca-trust/source/anchors/tls-ace.cert:ro,z \
  quay.io/rockylinux/rockylinux:9 \
  update-ca-trust
```

Read that command as three facts:

- The **anchors** mount is read-only and holds your CA. That is the input.
- The **extracted** mount is writable and empty. That is the output, and it lands in your home directory rather than in the container, which is why it survives the `--rm`.
- `--entrypoint ""` clears whatever the image would otherwise run, so `update-ca-trust` is the whole process. The container starts, extracts, and dies.

Confirm the bundle exists and contains your root:

```bash
ls -la ~/ace/tls/extracted/pem/
grep -c "BEGIN CERTIFICATE" ~/ace/tls/extracted/pem/tls-ca-bundle.pem
openssl crl2pkcs7 -nocrl -certfile ~/ace/tls/extracted/pem/tls-ca-bundle.pem \
  | openssl pkcs7 -print_certs -noout | grep "ACE Managed CA"
```

**Want:** a `pem/` directory holding `tls-ca-bundle.pem` (plus `email-`, `objsign-` and a `directory-hash/`), around 150 certificates — your root plus every public CA the base image ships — and one line naming `ACE Managed CA`.

From here on, **every service container mounts that directory**:

```
Volume=%h/ace/tls/extracted:/etc/pki/ca-trust/extracted:z
```

You will see that line in every quadlet from Lab 4 onward. It is not boilerplate to skim past — it is the reason the controller can validate a certificate the gateway presents, without either image knowing anything about your CA.

> **Reissuing the root** means regenerating `ca.cert`, re-running the extraction container, and restarting every service — but rebuilding nothing. That is the property this design is buying.

## Signing

```bash
vim ~/ace/tls/ace-cert
```

```bash
#!/bin/bash
# ace-cert <name> <dir> <hostname> [ext] [client]
#   name      basename for the pair, e.g. "tower"
#   dir       directory under ~/ace to write into, e.g. "awx"
#   hostname  the name the service is REACHED at, e.g. "ace-controller"
#   ext       certificate extension, default "crt" (some services want "cert")
#   client    pass "client" if this service also acts as a TLS *client*
#
# The directory and the hostname are separate arguments on purpose. They are
# the same for the gateway and differ for the controller, whose config lives in
# ~/ace/awx but which is reached at ace-controller. Deriving one from the other
# silently issues a certificate for a name nothing connects to.
set -euo pipefail

NAME=$1; DIR_NAME=$2; HOST=$3; EXT=${4:-crt}; CLIENT=${5:-}
CA=~/ace/tls
DIR=~/ace/$DIR_NAME/tls

EKU=""
[ "$CLIENT" = client ] && EKU=$'\nextendedKeyUsage=clientAuth'

mkdir -p "$DIR"

openssl genrsa -out "$DIR/$NAME.key" 4096
chmod 0640 "$DIR/$NAME.key"

openssl req -new -key "$DIR/$NAME.key" -subj "/CN=$HOST" \
  -addext "keyUsage=keyEncipherment,digitalSignature" \
  -addext "subjectAltName=DNS:$HOST,DNS:localhost,IP:127.0.0.1${EKU}" \
  -out "$DIR/$NAME.csr"

openssl x509 -req -in "$DIR/$NAME.csr" -sha256 \
  -CA "$CA/ca.cert" -CAkey "$CA/ca.key" -CAcreateserial \
  -copy_extensions copy \
  -days 365 \
  -extfile <(printf '%s\n' \
      "basicConstraints=CA:FALSE" \
      "subjectKeyIdentifier=hash" \
      "authorityKeyIdentifier=keyid:always") \
  -out "$DIR/$NAME.$EXT"

chmod 0644 "$DIR/$NAME.$EXT"
rm -f "$DIR/$NAME.csr"

echo "issued $DIR/$NAME.$EXT"
openssl x509 -in "$DIR/$NAME.$EXT" -noout -subject -dates -ext subjectAltName,keyUsage,extendedKeyUsage
```

```bash
chmod 0700 ~/ace/tls/ace-cert
```

### What the two-step signing looked like, and why it is one step here

The bare-metal track splits this in half: the node that needs a certificate generates the key and a CSR, the CSR travels to the CA host, the signed certificate travels back, and no private key ever crosses a machine boundary. That split is the whole design over there, and it is worth understanding.

Here there is one machine and one filesystem. A CSR that never leaves the directory it was written in is a formality, so the script does both halves in sequence and deletes the CSR when it is done. **Nothing about the certificates themselves changes** — the same extensions land in the same places for the same reasons:

| Extension | Set in | Why |
|---|---|---|
| `keyUsage=keyEncipherment,digitalSignature` | **the CSR** | the two things a TLS server key actually does |
| `subjectAltName` | **the CSR** | the only field modern clients check |
| `extendedKeyUsage=clientAuth` | **the CSR**, when asked | only for services that also *initiate* TLS connections |
| `basicConstraints=CA:FALSE` | the signer | a leaf must not sign further certificates, and a CA should never take that on trust from a request |
| `subjectKeyIdentifier=hash` | the signer | gives the certificate a stable fingerprint |
| `authorityKeyIdentifier=keyid:always` | the signer | pins which CA key signed it, so validators pick the right root after a rotation |

**The CSR carries what the requester knows; the CA imposes what only it can vouch for.** A requesting service knows its own names and what its key is for. It does *not* get to assert that it is a certificate authority — so `basicConstraints` is set by the signer, and a CSR claiming `CA:TRUE` gets it overwritten rather than honoured.

`-copy_extensions copy` is what carries the first three across. It is off by default in `openssl x509 -req`, deliberately, because a CSR is attacker-controlled input in the general case. Leave it out and your certificates come out with a CN and nothing else — no SAN, no key usage — and every modern client rejects them with a hostname error that never mentions SANs.

**Each SAN carries three names**: `ace-gateway`, `localhost`, and `127.0.0.1`. They are all the same interface, but they are not the same *string*, and TLS matches strings. Configs in later labs reach services by their `ace-` name; a stray health check or a `curl` from your shell may use `localhost`; something in a container may use the address. Covering all three costs nothing and saves an afternoon.

**There is no `notBefore` backdating, and on this track it cannot matter.** Certificates are validated against the verifier's clock, and a verifier whose clock trails the signer's rejects a fresh certificate as not-yet-valid — the usual fix is backdating by a day. Every container here shares your host's clock, so signer and verifier are the same clock and the skew is exactly zero. (The bare-metal track cannot rely on that and has a longer note about it.)

**Validity is 365 days.** Certificates that outlive the service are how you end up with a ten-year key nobody remembers generating.

## Verify

Issue a throwaway certificate and validate it against the extracted bundle — not against your host's trust store, but against the exact file the containers will use:

```bash
~/ace/tls/ace-cert smoketest smoketest ace-smoketest

openssl verify -CAfile ~/ace/tls/extracted/pem/tls-ca-bundle.pem \
  ~/ace/smoketest/tls/smoketest.crt

openssl x509 -in ~/ace/smoketest/tls/smoketest.crt -noout -ext subjectAltName

rm -rf ~/ace/smoketest
```

**Want:** `OK`, and a SAN listing `DNS:ace-smoketest, DNS:localhost, IP Address:127.0.0.1`.

That single `verify` proves three things at once: the CA signed it, the bundle your containers will mount accepts it, and the SAN survived.

## What later labs will do with this

| Lab | Directory | Hostname | Certificate | Role |
|---|---|---|---|---|
| [5 — the gateway](05-gateway.md) | `gateway` | `ace-gateway` | `gateway.cert` | server only |
| [6 — the controller](06-controller.md) | `awx` | `ace-controller` | `tower.cert` | server only |
| [8 — hub](08-hub.md) | `hub` | `ace-hub` | `pulp_webserver.crt` | server only |
| [9 — EDA](09-eda.md) | `eda` | `ace-eda` | `server.cert` | server only |

**The directory column is not the hostname column**, and the controller is where that bites: its configuration lives in `~/ace/awx/` — the layout the vendor's installer uses — while the service is reached at `ace-controller`. A script that derives one from the other issues a perfectly valid certificate for `ace-awx`, which nothing ever connects to, and the failure arrives one lab later as a hostname mismatch.

Every certificate here is a **server** certificate, so none of them passes `client` and none carries `extendedKeyUsage=clientAuth`. The fourth argument exists anyway, because it is the one distinction worth being able to make — and getting it wrong is instructive.

> **Do not add `client` to these.** A certificate whose `extendedKeyUsage` lists *only* `clientAuth` is not usable as a server certificate: OpenSSL verifies a server cert against the `serverAuth` purpose, and an EKU that omits it fails the check. nginx and envoy will still load and serve such a cert quite happily — `curl -k` works, a browser complains vaguely — but any client that verifies properly dies with
> ```
> [SSL: CERTIFICATE_VERIFY_FAILED] certificate verify failed: unsuitable certificate purpose
> ```
> and the failure surfaces far from the cause.
>
> The upstream deployment this build follows *does* mark the gateway and EDA as clients — but for a **second, separate certificate** on those hosts, a `cache` keypair used as an mTLS *client* credential to Redis. That is a different file with a different job from the one nginx serves. Our build talks to Redis over a socket and a plain port, so it has no `cache` certificate at all. If you ever add Redis mTLS, that is where the flag belongs — on its own certificate, never on the server's.

Note the inconsistent extensions — `.cert` for some, `.crt` for others. That is not a typo; the services genuinely disagree about what to call a certificate and their config files expect specific names, which is why the script takes the extension as an argument.

Next: [PostgreSQL and Redis](04-postgresql.md)
