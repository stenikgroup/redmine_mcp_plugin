# Internals

For maintainers: what the plugin changes around Doorkeeper and OAuth2 discovery, and how it journals through other plugins.

## Local patches

Two changes came from the stenikgroup fork and are not in the original plugin.

### `supported_scopes`

`app/controllers/mcp_metadata_controller.rb` enumerates the OAuth2 scopes advertised in both
discovery documents. Upstream advertised every scope Doorkeeper knows - every Redmine permission
plus `admin`, ~200 in all. Claude requests exactly what `scopes_supported` lists, so consent either
failed with `invalid_scope` or granted far more than the tools use.

This plugin advertises the permissions the tools on `/mcp` declare (`mcp_permissions`) and the ones they
check at runtime (`scopes`), an extension's tools included, dropping the write tools while the server
is read-only and the tools and scopes of plugins that are not installed, intersected with what
Doorkeeper will accept.
The resulting sets, and what the OAuth application must enable, are listed in
[scopes.md](scopes.md). The same file probes Doorkeeper for PKCE support rather than
assuming it, and advertises `S256` only - never `plain`, which MCP clients may not select.

PKCE support is confirmed on a live instance: `/.well-known/oauth-authorization-server` returns
`"code_challenge_methods_supported": ["S256"]`, verified against the live server.

### Narrowing an authorization request to its application

Claude requests exactly what `scopes_supported` lists, and both discovery documents are read before
any `client_id` is known, so the list cannot follow one application. Doorkeeper refuses the whole
request with `invalid_scope` when one requested scope is not enabled on the application, which left
"enable every advertised scope" as the only configuration that connected, and took away the lever
an administrator has to withhold a tool.

`lib/redmine_mcp_plugin/doorkeeper_scope_narrowing.rb` is prepended to
`Doorkeeper::AuthorizationsController` and replaces the requested `scope` with its intersection with
the application's scopes, before Doorkeeper validates it. RFC 6749 section 3.3 lets an authorization
server grant less than was requested; the consent screen lists the narrowed scopes and the token
response names them. An empty intersection is left as requested, so it is still refused rather than
falling back to Doorkeeper's default scopes.

Only a request whose `resource` parameter (RFC 8707, required of MCP clients) is this server's
`/mcp` address is narrowed, and only while the endpoint and OAuth2 are on. Any other OAuth client of
the same Redmine keeps Doorkeeper's stock behaviour.

### Doorkeeper URL generation

Redmine's layouts, and the plugins that extend them, reference controllers relatively:
`controller: 'my'` in the account link, `controller: 'people'` in redmine_people's avatar helper.
Rails resolves a relative controller against the one in the current request's path parameters,
which inside Doorkeeper is `doorkeeper/authorizations`, so every such reference becomes
`doorkeeper/<name>` and raises `UrlGenerationError` - a 500 on the OAuth2 consent screen of any
install whose layout links to a user.

`lib/redmine_mcp_plugin/doorkeeper_url_options.rb` makes a relative controller absolute in every
URL the three Doorkeeper controllers and their views build, as core's menus already do with
`use_absolute_controller`, and `init.rb` applies it in `after_initialize`. The recalled controller
itself is left alone: URLs built from it alone, such as the sudo mode password form's
`form_tag({})`, must still point at the Doorkeeper route. An earlier version stripped the
`doorkeeper/` prefix from the recall instead, and clicking Authorize with sudo mode on returned a
500 (`No route matches {:action=>"create", :controller=>"authorizations"}`).

The timing matters: plugin `init.rb` files run in a `to_prepare` block registered before the one in
which Redmine configures Doorkeeper, and touching a Doorkeeper controller before that configuration
binds it to `ActionController::Base` for the life of the process.

The first versions of this README asked administrators to patch Redmine's
`config/initializers/30-redmine.rb` by hand to strip the `doorkeeper/` prefix. That patch was never
part of Redmine: neither 6.1.5, 7.0.2 nor trunk (checked 2026-11-11) carry it, and none of them fix the
relative controllers either, so the plugin's module is still needed on Redmine 7. The core patch, on
the other hand, is no longer needed with plugin 0.2.1 or later, and can be removed: revert the file to
the version Redmine ships, restart, then open the OAuth2 consent screen and click Authorize with sudo
mode on. Until it is removed, the module puts back the recalled controller the patch strips, so an
install that still carries it keeps working.

## Journaling through redmine_checklists and redmineup_tags

Both plugins journal through controller hooks. The tools call the two listeners directly with the
keys each reads: the tags listener gets the issue and its real tag list, which it checks for
presence; the checklists listener gets the issue and its journal. `Redmine::Hook.call_hook` is not
used, since it would wake every listener on those hooks with a params object that is not a
request's. The tags filter `issue_tags` registers no operators, so `search_issues` offers it the
`list_optional` set, which is what the plugin's statement handles.

## Running the tests

The suite needs a Redmine checkout around the plugin, so it runs in two places.

**CI.** [`.github/workflows/tests.yml`](../.github/workflows/tests.yml) runs it on every pull request,
on every push to `main` and once a week, on each Ruby that each Redmine ref accepts in its
`Gemfile`:

| Redmine ref | Rails | Ruby |
|---|---|---|
| `6.1.0`, the floor in `init.rb` | 7.2 | 3.2 |
| `6.1-stable` | 7.2 | 3.2, 3.3, 3.4 |
| `7.0-stable` | 8.1 | 3.2, 3.3, 3.4, 4.0 |
| `master` (trunk) | 8.1 | 3.3, 3.4, 4.0 |

Rails is not an axis of its own: each Redmine ref pins one exact version. A job beside the matrix,
`Lint and coverage`, runs RuboCop and measures the line coverage of the plugin on `7.0-stable`, and
fails below the minimum set in the workflow. A last job, `Tests passed`, succeeds only when every
cell and that job do: it is the one check `main` requires, so the jobs can change without touching
the branch protection. The weekly run is there
because trunk and the stable branches move without a commit here, and a core removal reaches trunk
before any release.

**Locally.** [`test/docker/Dockerfile`](../test/docker/Dockerfile) builds one cell of that matrix.
The whole matrix is CI's job; while developing, one image is enough, and the two ends (the oldest
Redmine on the oldest Ruby, trunk on the newest) are worth a run before pushing. From the
repository root:

```bash
docker build --build-arg REDMINE_REF=master --build-arg RUBY_VERSION=4.0 -t redmine-mcp-test:master-ruby4.0 test/docker
```

```bash
docker run --rm -v "$PWD":/redmine/plugins/redmine_mcp_plugin redmine-mcp-test:master-ruby4.0
```

`REDMINE_REF` is any branch or tag of [redmine/redmine](https://github.com/redmine/redmine). An
image holds the Redmine sources as they were when it was built: rebuild with `--no-cache` to follow
a branch. To run one file, append the command:
`bin/rails test plugins/redmine_mcp_plugin/test/unit/protocol_test.rb`.

**Coverage.** Redmine's test helper writes a coverage report when `COVERAGE` is set, for the whole
application; [`test/coverage.rb`](../test/coverage.rb) reads the plugin's share of it, lists the
files that are not fully covered, and takes an optional minimum:

```bash
docker run --rm -e COVERAGE=1 -v "$PWD":/redmine/plugins/redmine_mcp_plugin redmine-mcp-test:master-ruby4.0 sh -c 'bin/rails redmine:plugins:test NAME=redmine_mcp_plugin && ruby plugins/redmine_mcp_plugin/test/coverage.rb 95'
```

What stays uncovered is the support of `redmine_checklists` and `redmineup_tags`: neither plugin is
installed in the test images, so their code paths never run.

**RuboCop.** The gems are Redmine's own. The configuration and the paths are named because Redmine's
root configuration excludes `plugins/`: without them RuboCop inspects no file and reports nothing.

```bash
docker run --rm -e BUNDLE_GEMFILE=/redmine/Gemfile -w /redmine/plugins/redmine_mcp_plugin -v "$PWD":/redmine/plugins/redmine_mcp_plugin redmine-mcp-test:master-ruby4.0 bundle exec rubocop -c .rubocop.yml app config lib test init.rb
```

[`.rubocop_todo.yml`](../.rubocop_todo.yml) lists what the code did not meet when the linter was
added, the size of the `Tool` base class above all. It is a ratchet: an offense it does not list
fails the build.
