# hub-web

nginx in front of pulpcore. The one image in this tutorial that is assembled rather than built from source.

| | |
|---|---|
| Source | upstream nginx image + a config you write |
| Built in | [Lab 8](../../docs/08-hub.md) |
| Status | not written |

Serves 8444. There is no application here — it muxes to pulpcore's api and content sockets. The hub UI itself comes from the platform console in the gateway image.
