# Appendix A1 — The EPEL uwsgi conflict

> **Not written yet, and possibly not applicable.** See below.

## What this is on the bare-metal track

A deliberate self-inflicted failure: install the distro's uwsgi package alongside the one pip built into the service venv, watch every worker die on import, and learn to read an ABI mismatch. A distro uwsgi links the system interpreter and cannot load a venv's C extensions. The fix is `excludepkgs`, and the lesson is why the tutorial builds uwsgi with pip in the first place.

## Why it may not survive containerization

The conflict needs two uwsgis on one filesystem. In a multi-stage build there is a real question whether that can still happen:

- The runtime image starts from a clean base with no prior uwsgi installed.
- `ace-images/gateway/Containerfile` does install `epel-release` in its final stage, so EPEL *is* enabled — the ingredients are present.
- Whether anything then pulls a distro uwsgi in, deliberately or as a dependency, is the open question.

## Outline

- [ ] Determine whether the conflict is reproducible inside a build stage at all
- [ ] If it is: keep the appendix, rewritten around a Containerfile that breaks
- [ ] If it is not: replace this appendix with the more interesting finding — *why* an image is immune, and what that says about build isolation generally
- [ ] Either way, record the answer rather than deleting the file silently

Decide this while writing [Lab 5](05-gateway.md), which is the first build that could hit it.
