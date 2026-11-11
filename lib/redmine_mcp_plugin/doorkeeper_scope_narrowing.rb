# frozen_string_literal: true

module RedmineMcpPlugin
  # An MCP client requests exactly what `scopes_supported` lists, and the discovery documents are
  # read before any client_id is known, so they cannot be tailored to one application. Doorkeeper
  # then refuses the whole request with `invalid_scope` as soon as one requested scope is not enabled
  # on the application, which made "enable every advertised scope" the only working configuration.
  #
  # The application is where an administrator withholds a tool: leave `delete_issues` unticked and no
  # token of that application can delete an issue. So an authorization request for /mcp is narrowed
  # to the scopes its application enables before Doorkeeper validates it. RFC 6749 section 3.3 lets an
  # authorization server grant less than was requested; the consent screen shows the narrowed list
  # and the token response names it in `scope`.
  #
  # Only requests that name this server as their `resource` (RFC 8707, which MCP clients must send)
  # are touched. Every other OAuth client of this Redmine keeps Doorkeeper's stock behaviour.
  module DoorkeeperScopeNarrowing
    def self.apply
      Doorkeeper::AuthorizationsController.prepend(self)
    end

    # The scope string narrowed to what the application enables, or unchanged when there is nothing
    # to narrow: no scope requested, an unknown client, an application with no scopes of its own.
    # An empty intersection is left as requested too, so Doorkeeper answers `invalid_scope` rather
    # than falling back to its default scopes.
    def self.narrow(scope, client_id)
      requested = scope.to_s.split
      return scope if requested.empty? || client_id.blank?

      application = Doorkeeper.config.application_model.find_by(uid: client_id.to_s)
      enabled     = application&.scopes.to_a.map(&:to_s)
      return scope if enabled.blank?

      narrowed = requested & enabled
      narrowed.empty? ? scope : narrowed.join(' ')
    end

    private

    def pre_auth_params
      permitted = super
      return permitted unless mcp_authorization_request?

      permitted.merge(scope: DoorkeeperScopeNarrowing.narrow(permitted[:scope], permitted[:client_id]))
    end

    def mcp_authorization_request?
      return false unless Settings.enabled? && Settings.oauth2_auth?

      params[:resource].to_s.chomp('/') == "#{PublicUrl.root(request)}/mcp"
    end
  end
end
