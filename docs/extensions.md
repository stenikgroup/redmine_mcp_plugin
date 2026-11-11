# Extensions

Another Redmine plugin can add tools to `/mcp`. They are served with this plugin's own: the same URL,
OAuth application and claude.ai connector, listed per user in the same way, and their permissions join
the advertised scopes. Nothing about that plugin's domain lives here. The plugin adds its tools from its
`init.rb`:

```ruby
# Without redmine_mcp_plugin, or with one older than add_tools, the tools are neither loaded nor served.
mcp = defined?(RedmineMcpPlugin::Endpoint) && RedmineMcpPlugin::Endpoint.respond_to?(:add_tools)
unless mcp
  Rails.autoloaders.main.ignore(File.join(__dir__, 'lib', 'redmine_mcp_plugin_invoices'))
  Rails.logger.error('[redmine_mcp_plugin_invoices] not served: redmine_mcp_plugin is absent or too old')
end

Redmine::Plugin.register :redmine_mcp_plugin_invoices do
  # ...
end

if mcp
  RedmineMcpPlugin::Endpoint.add_tools(:redmine_mcp_plugin_invoices) do
    next [] unless Redmine::Plugin.installed?(:redmine_contacts_invoices)

    [RedmineMcpPluginInvoices::Tools::ListInvoices, RedmineMcpPluginInvoices::Tools::GetInvoice]
  end
end
```

The first argument names the extension in log lines. The block returns its tools, each a
`RedmineMcpPlugin::Tool` subclass; an empty list adds nothing. It is called once, after every plugin has
loaded, so plugins may load in any order and the classes and permissions it names exist by then. The
tools follow this plugin's in `tools/list`. Each tool's `permission` and `scopes` are the extension's
OAuth scopes, advertised as this plugin's are; there is no separate list.

An extension never stops Redmine or `/mcp`. Each of these is logged at boot, and that extension's tools
are left out while `/mcp` serves everything else:

- the block is missing, raises (a misspelt class, say), or returns anything but a list of `Tool`
  subclasses;
- a tool name that this plugin or an earlier extension already serves, or that the list repeats;
- a `permission` or `scopes` entry that is not a Redmine permission, for a tool whose plugin is installed.

For example: `[redmine_mcp_plugin] redmine_mcp_plugin_invoices adds no tools to /mcp: ArgumentError: tool
name list_users is taken`. Extensions are added in the order Redmine loads plugins, which is
alphabetical, so the first to take a name keeps it. A syntax error in an extension's `lib/` still stops
Redmine, as in any plugin, because Redmine eager-loads every plugin's `lib/`.

An extension's tools share everything else with this plugin's:

- **Settings.** The enabled switch, the authentication modes, the REST API gate, read-only mode, the
  allowed origins, `max_results` and the excluded custom fields. A tool honours the last through the
  `shown_custom_fields` and `shown_custom_field_values` helpers and the `QueryTool` filters.
- **Request handling.** Authentication, the Origin and protocol-version checks, the JSON-RPC handling and
  the status codes.
- **Tool behaviour.** The `Tool` base: the permission check through `User#allowed_to?`, the read-only
  refusal, schema validation and coercion, the helpers, and the wording of every refusal. A call
  runs with `User.current` set to the tool's `user`, so core code that reads the global sees the
  same user. The validator enforces `type` (string, integer, number, boolean, array, object),
  `enum`, `minimum`, `required`, `additionalProperties` and the `type` and `enum` of an array's
  `items`; `description` and `format` are passed on unchecked. Any other keyword in a schema is
  served to clients and checked by nobody, and is logged at boot as
  `<tool> declares what /mcp does not enforce`.
- **Text.** The formatting guide and the parameter suffixes. User ids, project ids and the custom fields
  that render point to `list_users`, `list_projects` and `get_issue_fields`.
- **Discovery.** Doorkeeper, both discovery documents and the icon.

Every extension tool should declare a permission: a tool without one is listed to every user of `/mcp`.

What an administrator does:

1. **Install and restart,** as in [Deployment](installation.md#deployment).
2. **Enable the new scopes** on the existing MCP application: the ones
   `/.well-known/oauth-protected-resource` now lists. Until then a new connection fails with
   `invalid_scope`, because the client requests exactly that list. When the permissions come from a
   plugin that is already installed, they can be enabled before the restart.
3. **Grant the permissions** to the roles of the people who should use the tools.
4. **Reconnect.** A token keeps the scopes it was issued with, so each user reconnects the connector to
   see the new tools.

The URL, the connector and the firewall rule stay as they are.
