# git-server

A git daemon for the rulebook repository in [Lab 9](../../docs/09-eda.md).

| | |
|---|---|
| Base | `quay.io/centos/centos:stream9` |
| Built in | [Lab 9](../../docs/09-eda.md) |
| Status | **built** (2026-08-27) |

EDA projects are git repositories and EDA clones them with `--depth`, so the
lab needs a git server that supports shallow clones. `file://` is rejected by
EDA outright, and the dumb HTTP transport cannot do shallow — hence `git://`.

**`git daemon` is not part of the `git` package on EL9.** It ships separately in
`git-daemon`. Every other image in this tutorial has git and none of them can
run `git daemon`; the error (`git: 'daemon' is not a git command`) reads like a
typo rather than a missing package.
