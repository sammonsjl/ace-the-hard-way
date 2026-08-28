# Appendix A3 — Reaching the platform from other machines

By default this platform answers on the machine that runs it. Nothing about that is a limitation of the design — envoy already binds every interface — but three things stand between "it works locally" and "a laptop on the same network can log in".

## What is already true

```bash
ss -ltn | grep ':443 '
```

**Want:** `*:443`, not `127.0.0.1:443`. The listener comes from the gateway's registry ([Lab 5](05-gateway.md)), and the `http_port` row does not restrict the bind address, so envoy is listening on every interface from the moment you create it.

Prove the service itself is reachable before changing anything:

```bash
curl -k -o /dev/null -w "%{http_code}\n" https://<your-lan-ip>/
```

**Want:** `200`. If you get that, the service is fine and everything below is about the path to it.

> **Do [section 5](#5-the-client-may-refuse-before-it-sends-anything) first.** It costs one command and rules out the client entirely. Skip it and every other step here is guesswork — the failure modes look identical from a browser, and a browser that refuses on policy never sends a packet for your firewall to drop.

## 1. The certificate has to carry the names clients will use

```
curl: (60) SSL: no alternative certificate subject name matches target ipv4 address '192.168.1.3'
```

[Lab 3](03-internal-ca.md) issues certificates with three names: the service's `ace-` name, `localhost`, and `127.0.0.1`. None of those is how another machine reaches you.

`ace-cert` reads extra names from `~/ace/tls/extra-sans-<dir>`, one per line — a line containing dots and digits is treated as an IP, anything else as a DNS name:

```bash
cat > ~/ace/tls/extra-sans-gateway <<'EOF'
myhost
myhost.lan
192.168.1.3
192.168.1.83
EOF

~/ace/tls/ace-cert gateway gateway ace-gateway cert
systemctl --user restart ace-gateway ace-envoy
```

**Put every address in.** A machine with both wired and wireless interfaces answers on both, and which one a client uses is not your decision. Verify:

```bash
openssl x509 -in ~/ace/gateway/tls/gateway.cert -noout -ext subjectAltName
curl --cacert ~/ace/tls/extracted/pem/tls-ca-bundle.pem \
     -o /dev/null -w "%{http_code}\n" https://192.168.1.3/
```

**Want:** `200` **without** `-k`.

> **Do not assume `.local` works.** mDNS advertises whatever avahi decides is interesting, and on a machine running Docker that can be the `docker0` bridge:
> ```
> $ getent ahostsv4 myhost.local
> 172.17.0.1      STREAM myhost.local
> ```
> That address is unreachable from the network and may belong to a *down* interface. Check what your name actually resolves to before building anything on it; `ip route get 1.1.1.1` tells you which address the machine really uses.

## 2. The gateway has to know its own external URL

The gateway generates links and redirects from a setting, not from the request. Out of the box it is `https://localhost:9080` — wrong host *and* wrong port for this build:

```bash
A="admin:$(cat ~/ace/gateway/pw-admin)"
C=~/ace/tls/extracted/pem/tls-ca-bundle.pem
curl -u "$A" --cacert $C https://ace-gateway:8446/api/gateway/v1/settings/all/ \
  | python3 -c 'import sys,json;print(json.load(sys.stdin)["gateway_proxy_url"])'

curl -u "$A" --cacert $C -H 'Content-Type: application/json' -X PUT \
  https://ace-gateway:8446/api/gateway/v1/settings/all/ \
  -d '{"gateway_proxy_url":"https://192.168.1.3"}'
```

**`PUT`, not `PATCH`** — the settings endpoint rejects `PATCH` with `Method "PATCH" not allowed.`

**And a bare hostname is rejected**: `https://myhost` comes back as `is not a valid URL`. It wants a dotted name or an address.

## 3. The privileged-port floor

The front door is 443, which a rootless container cannot bind until the machine says unprivileged processes may. [Lab 5](05-gateway.md) covers the sysctl and why no systemd setting substitutes for it; if you skipped it, envoy will be running with no listener at all:

```bash
sysctl net.ipv4.ip_unprivileged_port_start   # want: 443
```

## 4. The firewall

This is the step that looks like a broken service. The port is open on the host, the certificate is right, and connections from other machines simply hang or refuse — because a default-deny firewall never lets them arrive.

```bash
sudo ufw status
sudo ufw allow 443/tcp comment 'ACE platform front door'
```

Restrict it to your own network if you would rather not serve the whole world:

```bash
sudo ufw allow from 192.168.1.0/24 to any port 443 proto tcp comment 'ACE platform front door'
```

## 5. The client may refuse before it sends anything

Before blaming the network, rule out the browser. A managed browser — Edge or Chrome under enterprise policy, and increasingly the defaults — can refuse to connect to private-network addresses and **never put a packet on the wire**. Corporate policy blocking access to local hosts is a real configuration and it produces a failure that looks exactly like a firewall.

The symptom is indistinguishable from a network problem if you only look at the browser:

```
Hmmm… can't reach this page
https://192.168.1.3/ is unreachable
ERR_ADDRESS_UNREACHABLE
```

**The test that separates the two takes one command on the server:**

```bash
sudo tcpdump -i any -n "host <client-ip> and tcp[tcpflags] & tcp-syn != 0"
```

`tcpdump` sees packets *before* netfilter, so anything that reaches the wire shows up even when the firewall drops it. Then load the page.

| tcpdump shows | Meaning |
|---|---|
| Nothing at all | The client never sent it — browser policy, a proxy, or the wrong machine. **Not your firewall.** |
| SYNs arriving, no reply | The server is dropping them — now go and read your firewall rules |
| SYNs and SYN-ACKs | It works; the problem is TLS or the application |

Two corroborating checks, both quick:

- **`curl` from the same machine.** If `curl -v http://<server>:<port>/` succeeds where the browser fails, the network is fine and the browser is the variable.
- **`edge://policy` or `chrome://policy`.** Managed policies are listed there. Look for URL blocklists and anything governing private-network or local-host access.

> **The general principle is worth more than the specific fix:** when a server sees no packet but another tool on the same client works, the fault is in the client application, not the network. Firewalls drop packets that *arrive*. A browser refusing on policy never sends one, and no amount of `ufw` archaeology on the server will reveal it.

## 6. Clients have to trust the CA

The certificate is signed by the CA you made in [Lab 3](03-internal-ca.md), which nothing else on your network has heard of. Every client either accepts a browser warning or installs the root:

```bash
# copy this to the client machine — the CERTIFICATE only, never ca.key
cat ~/ace/tls/ca.cert
```

| Client | Install |
|---|---|
| Fedora / RHEL | `sudo cp ca.cert /etc/pki/ca-trust/source/anchors/ && sudo update-ca-trust` |
| Debian / Ubuntu | `sudo cp ca.cert /usr/local/share/ca-certificates/ace.crt && sudo update-ca-certificates` |
| macOS | Keychain Access → System → drag it in → set to *Always Trust* |
| Firefox | Settings → Privacy & Security → Certificates → View → Authorities → Import |

Firefox keeps its own trust store and ignores the system one, which is why it is listed separately.

> **`ca.key` never leaves this machine.** Copying the certificate lets a client *verify* your platform; copying the key would let anyone mint a certificate it trusts.

## Verify from the other machine

```bash
curl --cacert ca.cert -o /dev/null -w "%{http_code}\n" https://192.168.1.3/
curl --cacert ca.cert -u admin:<password> https://192.168.1.3/api/gateway/v1/ping/
```

**Want:** `200`, and a ping reporting `proxy_connected: true`. Then open the console in a browser and log in.

## What this does not do

The `ace-*` names still resolve only on the host — they are `/etc/hosts` entries from [Lab 2](02-host.md), and the services use them to talk to each other. Clients reach the platform through the front door on 443 and never need them.

Nothing else is exposed. The component ports (8443, 8444, 8445, 8446) bind on the host and are not opened here, which is the intended shape: one door, and envoy authorising everything through it.
