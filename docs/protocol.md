# Protocol

2026-07-28 is stateless: no `initialize` handshake and no `Mcp-Session-Id`. `server/discover` is
implemented, as that revision requires. Results carry `resultType` and server identity in `_meta`, and
list results carry `ttlMs` and `cacheScope: private` because the tool set varies per caller.

2025-11-25 and 2025-06-18 are the handshake revisions most shipped clients still speak. `initialize` is
answered for those.

One JSON response per POST, no SSE. JSON-RPC batching is refused rather than half processed. The
`Origin` header is validated on every request, against the host name in Redmine's settings and the
allowed origins of the plugin, so that a foreign web page cannot call the endpoint through a
visitor's browser. Non-browser clients send none and are unaffected.

## GET and DELETE on `/mcp`

The endpoint has no server-to-client stream and never issued a session, so `GET` and `DELETE` both
end in 405 - but **only for a request that has already authenticated**. Authentication is a
`before_action` and runs first, so the status a client actually sees depends on how far up the chain
it gets:

| Condition | Status |
|---|---|
| Endpoint disabled in plugin settings | 403 |
| `Origin` present and not allowed | 403 |
| Session cookie on a `POST` with no `Origin`, or a body that is not `application/json` | 403 |
| No authentication mode enabled | 503 |
| No or invalid credential | 401, with `WWW-Authenticate` when OAuth2 mode is on |
| Authenticated | 405 |

So an unauthenticated `GET /mcp` returns 401, not 405. That is the intended behaviour: the endpoint
does not describe itself to anonymous callers beyond pointing them at the discovery documents.
