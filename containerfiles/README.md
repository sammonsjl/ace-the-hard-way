# containerfiles/

One directory per image: the `Containerfile` for it, plus anything that has to be `COPY`'d in — nginx configs, supervisord fragments, entrypoints.

## Why these are in the repo at all

The [bare-metal track](../../../tree/main) ships almost nothing: every config file in it is written by the reader, into a heredoc, at the moment the lab needs it. This track cannot work that way, and the reason is worth stating rather than glossing.

A Containerfile is a **build input**. `podman build` reads it from disk before anything else happens, so it has to exist as a file before the lab can proceed — unlike a shell command, which the reader types and the shell consumes directly. There is no honest way to "type" a Containerfile into a build.

So they are here, finished and working. The labs' job is not to dictate them keystroke by keystroke but to explain what is in them and why: which stage does what, which lines are load-bearing, and which are there because of a failure that is not obvious from reading. Every one of them has a `NOTES.md` recording what was learned building it.

**Read them before you build.** Rewriting one from the lab's description is a good exercise and you will learn more doing it; building the shipped file and reading along is also legitimate. What is not useful is running `podman build` on a file you have never opened — at that point you are back to pulling someone else's image, which is the thing this tutorial exists to avoid.

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
