# ee-minimal

The execution environment — where jobs actually run.

| | |
|---|---|
| Built with | `ansible-builder` |
| Built in | [Lab 7](../../docs/07-execution.md) |
| Status | not written |

Not a Containerfile you write directly: `ansible-builder` generates one from an execution-environment definition, which is itself worth understanding rather than treating as a black box.

`quay.io/ansible/awx-ee` exists and is what most people use. Building it is the point.
