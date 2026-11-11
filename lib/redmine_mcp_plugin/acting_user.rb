# frozen_string_literal: true

module RedmineMcpPlugin
  # Who a tool acts for, and how they authenticated. Prepended to Tool.
  #
  # A tool is given its user, but core reads User.current in many places a tool
  # goes through and cannot pass a user to: the base scope of a query, the
  # issue history helper, Project#visible? with no argument. Two sources for
  # one fact, and each tool that met such a place used to assert they agreed.
  #
  # #call makes them agree instead: the whole call, permission checks and
  # schema validation included, runs with User.current set to the tool's user,
  # and whatever was current before is put back. `user` is then the one acting
  # user, a tool has nothing to assert, and a new one cannot forget to.
  module ActingUser
    def call(arguments)
      previous = User.current
      User.current = user
      super
    ensure
      User.current = previous
    end

    def auth_mode    = auth[:mode]
    def oauth?       = auth[:mode] == :oauth2
    def oauth_scopes = auth[:scopes]
  end
end
