# frozen_string_literal: true

module RedmineMcpPlugin
  # The tools /mcp serves: this plugin's, then those other plugins add with add_tools.
  module Endpoint
    class << self
      # From another plugin's init.rb, which may run before this plugin's. The block is called after every
      # plugin has loaded, so its classes and permissions exist, and inside a rescue, so it cannot stop Redmine.
      def add_tools(name, &tools)
        added[name.to_s] = tools
        @added_tools = nil
      end

      def tools = Registry.all + added_tools

      # Tools this user may see. tools/list is permitted to vary by the
      # authorization on the request; the 2026-07-28 spec says so explicitly,
      # and it means a scope-narrowed token is not shown tools it cannot call.
      def visible_to(user) = tools.select { |tool| tool.available_to?(user) }

      def find(name, user) = visible_to(user).detect { |tool| tool.mcp_name == name.to_s }

      private

      def added = (@added ||= {})

      # A broken extension is logged once and left out; /mcp serves everything else.
      def added_tools
        @added_tools ||= added.each_with_object([]) do |(name, block), served|
          served.concat(checked(block&.call, Registry.all + served))
        rescue StandardError => e
          Rails.logger.error("[redmine_mcp_plugin] #{name} adds no tools to /mcp: #{e.class}: #{e.message}")
        end
      end

      def checked(tools, served)
        unless tools.is_a?(Array) && tools.all? { |tool| tool.is_a?(Class) && tool < Tool && tool.mcp_name.present? }
          raise ArgumentError, 'the block must return a list of RedmineMcpPlugin::Tool subclasses'
        end

        taken = (served + tools).map(&:mcp_name).tally.select { |_name, count| count > 1 }.keys
        raise ArgumentError, "tool name #{taken.join(', ')} is taken" if taken.any?

        # A tool of a plugin that is not installed is never served, and its permissions do not exist.
        unknown = tools.select(&:installed?).flat_map { |tool| tool.mcp_permissions + tool.mcp_scopes }
                                            .map(&:to_sym).uniq.reject { |scope| Redmine::AccessControl.permission(scope) }
        raise ArgumentError, "#{unknown.join(', ')} is not a Redmine permission" if unknown.any?

        tools
      end
    end
  end
end
