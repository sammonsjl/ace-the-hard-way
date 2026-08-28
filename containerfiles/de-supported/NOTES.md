# de-supported

The decision environment — where rulebooks run, as opposed to playbooks.

| | |
|---|---|
| Built with | `ansible-builder` |
| Built in | [Lab 7](../../docs/07-execution.md), used in [Lab 9](../../docs/09-eda.md) |
| Status | **built** (2026-08-27) |

Same mechanism as `ee-minimal`, different contents: ansible-rulebook and its dependencies rather than ansible-core and collections. Built alongside the EE in Lab 7 because the pattern is identical and splitting it across two labs would teach it twice.

## Built 2026-08-27

Installs a JVM: ansible-rulebook's event engine is Drools, reached through jpy.
That is why this image is roughly twice the size of the execution environment.
