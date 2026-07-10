# Lab 15 — The gateway

## What you will have at the end

The platform gateway built from source, with envoy from a release binary in front.

## Outline (to be written)

- [ ] Clone the gateway (Jewel) source at a pinned ref; same venv treatment as AWX (Lab 5)
- [ ] Gateway init: migrations, admin, settings — mirror the installer's chain
- [ ] **envoy from the release binary** (another real tarball) + hand-written config and unit
- [ ] Verify: gateway answers on its port; envoy proxies to it

> Milestone note: Labs 1–14 are a complete, working controller. The gateway (15–16) adds the single-login platform layer. If Jewel-from-source turns out to be quicksand, ship 1–14 first.

Next: [Service registration](16-service-registration.md)
