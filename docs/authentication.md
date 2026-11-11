# Authentication

Four modes, each switchable in Administration → Plugins → Redmine MCP Server. Each is a code path
Redmine core already implements. OAuth2 alone is the recommended setup, as [installation.md](installation.md#plugin-settings) explains; the other three are documented because the code
supports them.

| Mode | Plugin default | Notes |
|---|---|---|
| OAuth2 | on | Per-user access tokens from Redmine's own provider. Scopes can narrow a token below the issuing user's own permissions. |
| API key | on | The `X-Redmine-API-Key` header, and only the header: a `?key=` in the URL is not read, as it would stay in access logs. Carries the user's full permissions, no scope narrowing. |
| HTTP Basic | off | Reusable credentials on every request. Refused for accounts with 2FA active, matching core. An API key as the username is taken only while the API key mode is on. |
| Session cookie | off | For clients running in the browser. The request must be `application/json` and carry an `Origin` header that is this Redmine's or an allowed one. |

Every token mode also requires the REST API to be enabled in Administration → Settings → API.

For OAuth2, register an application under Administration → Applications, then send
`Authorization: Bearer <token>`.

## Discovery

Two documents let a client find the authorization server without being told where it is:

```
/.well-known/oauth-protected-resource        RFC 9728
/.well-known/oauth-protected-resource/mcp
/.well-known/oauth-authorization-server      RFC 8414
```

A 401 from `/mcp` carries `WWW-Authenticate: Bearer realm="Redmine", resource_metadata="..."` pointing
at the first of those. Every URL in these documents is built from Administration → Settings →
General → "Host name and path" and "Protocol", not from the request's `Host` header, so check that
setting names the address clients use. Both are served only while the endpoint and OAuth2 mode are enabled, and 404
otherwise: advertising a disabled endpoint only sends clients down a dead end.

When the request presented a bearer token that is expired, revoked, unknown or owned by a locked
user, the challenge adds `error="invalid_token"` and an `error_description` (RFC 6750 3.1), which
tells the client to refresh its token rather than ask the user to authorize again. A request with no
token gets no error code. Each refused token is logged at `warn`, so it shows even when Redmine logs
nothing below that level:

```
[redmine_mcp_plugin] OAuth2 token refused (expired): token=42 user=5 app=1 created_at=... expires_in=7200 revoked_at=
```

An expired token is refused about every two hours per connected user, before the client refreshes
it: those lines are expected. A user who had to reconnect shows as a token that is refused and then
never followed by a new one for the same user and application in `oauth_access_tokens`.

Redmine has no dynamic client registration (RFC 7591), so no `registration_endpoint` is advertised.
Create the application by hand and give the client its id and secret.

## Client configuration

For a client that takes a fixed header, such as a `curl` test. Access tokens expire after two hours,
so this is for testing; claude.ai reads the discovery documents and runs the OAuth2 flow itself.

```json
{
  "mcpServers": {
    "redmine": {
      "type": "http",
      "url": "https://redmine.example.com/mcp",
      "headers": { "Authorization": "Bearer YOUR_OAUTH2_TOKEN" }
    }
  }
}
```
