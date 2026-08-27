# containerfiles/

One directory per image. Each holds the `Containerfile` you write in the lab that needs it, plus anything that has to be `COPY`'d in — nginx configs, supervisord fragments, entrypoints.

**Nothing here is written yet.** Each directory carries a `NOTES.md` recording what the image is, where its source comes from, and what is already known about building it.

## The rules every image in here follows

- **Pin the upstream ref.** Every source repo is cloned at a commit, declared as an `ARG` at the top of the Containerfile so it can be overridden per build. A moving `main` is not reproducible and this tutorial is meant to still work in a year.
- **Nothing secret is `COPY`'d.** Keys, certificates and passwords are mounted at run time. A layer is a thing you can push, pull and unpack — see [Lab 3](../docs/03-internal-ca.md).
- **Multi-stage, always.** Build tools do not belong in a runtime image. Node builds a UI in one stage and never appears in the final one.
- **The base is EL9.** `quay.io/centos/centos:stream9` unless an upstream project's own image forces otherwise (hub builds on `pulp/base`). Your host's distro stops mattering here.
- **Replicate the end state, never the files.** These images are built from Apache-2.0 upstream source. Observing what a vendor image does is fine and is how the gateway was worked out; copying its files is not.

## What is not built here

| | Why |
|---|---|
| envoy | Building it means bazel and hours. The upstream release binary goes into a slim image instead — assembled, not compiled. |
| PostgreSQL | Upstream image, configured by mounted files. Not the lesson. |
| Redis | Same. |

Every other image in the platform is built from source, and the labs say so at the moment they do it.

## Reference implementations

Two of these images already exist as working builds in `ace-images`, written before this tutorial:

- `gateway` — jewel + ansible-ui, four stages
- `hub` — galaxy_ng on `pulp/base`

They are worth reading and worth not pasting. The labs build them a line at a time because that is the entire point.
