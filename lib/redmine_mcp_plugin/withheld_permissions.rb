# frozen_string_literal: true

module RedmineMcpPlugin
  # Makes core's role-based SQL honour a permission the caller lacks, for the
  # length of a block.
  #
  # Project.allowed_to_condition asks each role and never the OAuth token, so
  # the SQL core builds from it grants what a scope-narrowed token must not
  # have. A tool can usually check the permission itself, before or after the
  # query. It cannot when the condition sits inside a query core runs on its
  # own: the search, which matches private notes under
  # allowed_to_condition(user, :view_private_notes).
  #
  # Inside the block that condition is false for the permissions named, on this
  # thread only; every other call reaches core untouched. The module is
  # prepended on first use rather than at boot, so a reloaded Project gets it
  # again.
  module WithheldPermissions
    KEY = :redmine_mcp_plugin_withheld_permissions

    def self.during(*permissions)
      Project.singleton_class.prepend(self) unless Project.singleton_class.include?(self)
      previous = Thread.current[KEY]
      Thread.current[KEY] = permissions.map(&:to_sym)
      yield
    ensure
      Thread.current[KEY] = previous
    end

    def allowed_to_condition(user, permission, options = {})
      return '1=0' if Thread.current[KEY]&.include?(permission.to_sym)

      super
    end
  end
end
