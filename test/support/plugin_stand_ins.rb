# frozen_string_literal: true

require 'singleton'

# Stand-ins for redmine_checklists, redmineup_tags and additional_tags.
#
# The first two cannot be installed in the test images or in CI, the third
# needs a plugin of its own and a recent Redmine, and without them the code
# that reaches into them never runs. These are not the plugins: they
# are the smallest thing that honours the contract in
# RedmineMcpPlugin::Integrations, written from what the tools call and from
# what their comments say the plugins do. A test over them proves the tools'
# own logic, the permissions they check, the refusals they word and the
# replies they build. It does not prove the real plugins still behave this way;
# the contract check at boot is what watches for that.
#
# Loading this file changes the test process for good: two tables, two models'
# worth of methods on Issue, five permissions. The plugins are still "not
# installed" until a test says otherwise, through McpPluginStandIns#with_plugin.
#
# When the real redmine_checklists or additional_tags is installed in the
# Redmine under test, its stand-in steps aside and the same tests run over the
# plugin itself. One tags stand-in serves both tags plugins: it reads tag_list,
# add_tag_list and remove_tag_list as redmineup_tags does, of which
# additional_tags is only ever sent the first.
module McpPluginStandIns
  CHECKLIST_PERMISSIONS  = %i[view_checklists done_checklists edit_checklists].freeze
  TAG_PERMISSIONS        = %i[edit_tags create_tags].freeze
  ISSUE_TAG_PERMISSIONS  = %i[view_issue_tags edit_issue_tags create_issue_tags].freeze
  REAL_CHECKLISTS        = Redmine::Plugin.installed?(:redmine_checklists)
  REAL_ADDITIONAL_TAGS   = Redmine::Plugin.installed?(:additional_tags)

  # additional_tags keeps issue tags behind a setting that is off by default.
  def issue_tags_active!(enabled)
    return AdditionalTags.active_issue_tags = enabled unless REAL_ADDITIONAL_TAGS

    # A symbol key, as the plugin reads it.
    settings = Setting.plugin_additional_tags.dup
    settings[:active_issue_tags] = enabled ? '1' : '0'
    Setting.plugin_additional_tags = settings
  end

  # The stand-in journals a list change, as the edition with a history does.
  def checklists_journaled? = !REAL_CHECKLISTS || JournalChecklistHistory.new('[]', '[]').diff.key?(:added)

  # The plugin's own setting, or the stand-in's switch.
  def checklist_done_ratio!(enabled)
    return RedmineChecklists.issue_done_ratio = enabled unless REAL_CHECKLISTS

    Setting.plugin_redmine_checklists = { 'save_log' => '1', 'issue_done_ratio' => enabled ? '1' : '0' }
  end

  # Runs the block with these plugins installed, as far as the server can tell.
  def with_plugin(*ids)
    Redmine::Plugin.stubs(:installed?).returns(false)
    ids.each { |id| Redmine::Plugin.stubs(:installed?).with(id).returns(true) }
    RedmineMcpPlugin::Integrations.reset!
    yield
  ensure
    Redmine::Plugin.unstub(:installed?)
    RedmineMcpPlugin::Integrations.reset!
  end

  def self.install!
    return if @installed

    create_tables
    register_permissions
    Issue.include(ChecklistIssue) unless REAL_CHECKLISTS
    unless REAL_ADDITIONAL_TAGS
      Issue.prepend(TaggedIssue)
      Issue.extend(TaggedIssue::ClassMethods)
    end
    @installed = true
  end

  def self.create_tables
    connection = ActiveRecord::Base.connection
    unless REAL_CHECKLISTS || connection.table_exists?(:checklists)
      connection.create_table(:checklists) do |t|
        t.integer :issue_id, null: false
        t.string  :subject
        t.boolean :is_done, default: false, null: false
        t.boolean :is_section, default: false, null: false
        t.integer :position
      end
    end
    return if connection.table_exists?(:mcp_stand_in_tags)

    connection.create_table(:mcp_stand_in_tags) do |t|
      t.integer :issue_id, null: false
      t.string  :name, null: false
    end
  end

  def self.register_permissions
    Redmine::AccessControl.map do |map|
      map.project_module :issue_tracking do |issues|
        unless REAL_CHECKLISTS
          issues.permission :view_checklists, {}, read: true
          issues.permission :done_checklists, {}
          issues.permission :edit_checklists, {}
        end
        issues.permission :edit_tags, {}
        issues.permission :create_tags, {}
        unless REAL_ADDITIONAL_TAGS
          issues.permission :view_issue_tags, {}, read: true
          issues.permission :edit_issue_tags, {}
          issues.permission :create_issue_tags, {}
        end
      end
    end
  end

  # --- redmine_checklists -------------------------------------------------------

  module ChecklistIssue
    def self.included(base)
      base.has_many :checklists, -> { order(:position, :id) }, dependent: :destroy
      # As the plugin: an item hash without a subject is dropped.
      base.accepts_nested_attributes_for :checklists, reject_if: ->(attributes) { attributes['subject'].blank? }
      base.attr_accessor :old_checklists
      base.safe_attributes 'checklists_attributes',
                           if: lambda { |issue, user|
                             user.allowed_to?(:done_checklists, issue.project) || user.allowed_to?(:edit_checklists, issue.project)
                           }
    end
  end
end

unless McpPluginStandIns::REAL_CHECKLISTS
  class Checklist < ApplicationRecord
    belongs_to :issue

    # As the plugin's list: a new item goes to the bottom.
    before_create { self.position ||= (Checklist.where(issue_id: issue_id).maximum(:position) || 0) + 1 }

    # The first versions journaled "[x] item" text; later ones the list as JSON.
    def self.old_format?(detail)
      JSON.parse(detail.value.to_s).is_a?(Array) ? false : true
    rescue JSON::ParserError
      true
    end

    def as_json(*)
      { 'id' => id, 'subject' => subject, 'is_done' => is_done, 'is_section' => is_section }
    end
  end

  module RedmineChecklists
    class << self
      attr_writer :issue_done_ratio

      def issue_done_ratio? = @issue_done_ratio ? true : false
    end

    module Hooks
      class ControllerIssuesHook
        include Singleton

        # Journals the list on both sides when it changed, then recalculates the
        # done ratio from the items when the plugin's setting asks for it.
        def controller_issues_edit_after_save(context)
          issue   = context[:issue]
          journal = context[:journal]
          current = issue.checklists.reload.to_json
          if journal && issue.old_checklists.present? && issue.old_checklists != current
            journal.details << JournalDetail.new(property: 'attr', prop_key: 'checklist', old_value: issue.old_checklists, value: current)
            journal.save! if journal.new_record?
          end
          recalculate(issue) if RedmineChecklists.issue_done_ratio?
        end

        def recalculate(issue)
          items = issue.checklists.reject(&:is_section)
          return if items.empty?

          issue.update_column(:done_ratio, (100.0 * items.count(&:is_done) / items.size).round(-1))
        end
      end
    end
  end

  # What changed between two journaled lists, by item id.
  class JournalChecklistHistory
    Item = Struct.new(:id, :subject, :is_done)

    def initialize(was, became)
      @was    = parse(was)
      @became = parse(became)
    end

    def diff
      kept = @became.keys & @was.keys
      {
        added: @became.values_at(*(@became.keys - @was.keys)),
        removed: @was.values_at(*(@was.keys - @became.keys)),
        done: kept.select { |id| @became[id].is_done && !@was[id].is_done }.map { |id| @became[id] },
        undone: kept.select { |id| !@became[id].is_done && @was[id].is_done }.map { |id| @became[id] },
        renamed: kept.reject { |id| @became[id].subject == @was[id].subject }.map { |id| [@was[id], @became[id]] }
      }
    end

    private

    def parse(json)
      JSON.parse(json.to_s).to_h { |row| [row['id'], Item.new(row['id'], row['subject'], row['is_done'])] }
    end
  end
end

# --- redmineup_tags -------------------------------------------------------------

module McpPluginStandIns
  Tag = Struct.new(:name)

  # tag_list, and the three keys the plugin reads off safe_attributes=, as
  # symbols, and applies only under edit_tags. A tag that does not exist yet is
  # dropped without create_tags.
  module TaggedIssue
    module ClassMethods
      def all_tags
        ActiveRecord::Base.connection.select_values('SELECT DISTINCT name FROM mcp_stand_in_tags ORDER BY name').map { |name| Tag.new(name) }
      end

      # additional_tags' name for the same list, kept to what the user may see.
      def available_tags(**) = all_tags
    end

    def tag_list
      @tag_list ||= new_record? ? [] : stored_tags
    end

    TAG_KEYS = %i[tag_list add_tag_list remove_tag_list].freeze

    def safe_attributes=(attrs, user = User.current)
      attrs = take_tags(attrs.with_indifferent_access, user) if attrs.is_a?(Hash)
      super
    end

    def tag_list_was = @tag_list_was || tag_list

    def reload(*)
      @tag_list = nil
      super
    end

    def self.prepended(base)
      base.after_save :store_tags
    end

    private

    # Applies the tag keys under edit_tags, and hands the rest back to core.
    def take_tags(attrs, user)
      if attrs.slice(*TAG_KEYS).any? && tags_allowed?(user, :edit_tags, :edit_issue_tags)
        names = attrs.key?(:tag_list) ? Array(attrs[:tag_list]) : tag_list.dup
        names = (names + Array(attrs[:add_tag_list])) - Array(attrs[:remove_tag_list])
        names &= (self.class.all_tags.map(&:name) + tag_list) unless tags_allowed?(user, :create_tags, :create_issue_tags)
        @tag_list_was = tag_list.dup
        @tag_list     = names.map(&:to_s).uniq
        @tags_changed = true
      end
      attrs.except(*TAG_KEYS)
    end

    # Either plugin's permission: the stand-in does not know which one is "installed".
    def tags_allowed?(user, *permissions)
      permissions.any? { |permission| user.allowed_to?(permission, project) }
    end

    def stored_tags
      self.class.connection.select_values("SELECT name FROM mcp_stand_in_tags WHERE issue_id = #{id.to_i} ORDER BY id")
    end

    def store_tags
      return unless @tags_changed

      self.class.connection.execute("DELETE FROM mcp_stand_in_tags WHERE issue_id = #{id.to_i}")
      @tag_list.each do |name|
        self.class.connection.execute(
          self.class.sanitize_sql_array(['INSERT INTO mcp_stand_in_tags (issue_id, name) VALUES (?, ?)', id, name])
        )
      end
      @tags_changed = false
    end
  end
end

module RedmineupTags
  module Hooks
    class ModelIssueHook
      include Singleton

      # Journals the tag list, before the save, when the issue has a journal.
      def controller_issues_edit_before_save(context)
        issue   = context[:issue]
        journal = issue.current_journal
        return if journal.nil? || issue.tag_list_was == issue.tag_list

        journal.details << JournalDetail.new(property: 'attr', prop_key: 'tag_list',
                                             old_value: issue.tag_list_was.join(', '), value: issue.tag_list.join(', '))
      end
    end
  end
end

unless McpPluginStandIns::REAL_ADDITIONAL_TAGS
  module AdditionalTags
    class << self
      attr_writer :active_issue_tags

      def setting?(name) = name.to_sym == :active_issue_tags && @active_issue_tags ? true : false
    end
  end
end

McpPluginStandIns.install!
