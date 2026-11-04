# frozen_string_literal: true

require 'did_you_mean'

module RedmineMcpPlugin
  # Filtering, sorting, grouping and describing against a core Query subclass.
  # A module, not more helpers on Tool: only some tools are query-backed.
  #
  # A tool declares NAMED_FILTERS, its named parameters and the filter each
  # stands for, and AUTHORISED_FILTERS, the filters that name a project, an
  # issue or a project's record, as field => { operator => kind }.
  module QueryTool
    # Their values are the user directory or the project list; describe names
    # the paged tool that already answers those instead of inlining them.
    USER_FILTERS    = %w[assigned_to_id author_id watcher_id updated_by last_updated_by user_id].freeze
    PROJECT_FILTERS = %w[project_id subproject_id].freeze
    MAX_VALUES      = 50
    MAX_SUGGESTIONS = 5
    VERSION_FIELD   = { '=' => :version }.freeze
    RELATION_NOTE   = 'For = and !, issue ids, comma separated; for =p, =!p and !p, a project from values.'

    private

    # Core drops an unknown field silently, and a dropped filter widens the
    # result, which reads to the caller exactly like an answer.
    def set_filter!(query, field, operator, values = '')
      available = available_filters(query)[field]
      unknown_filter!(query, field) unless available

      legal = operators_for(available[:type])
      unless legal.include?(operator)
        raise ToolError, "Operator #{operator.inspect} is not valid for #{field.inspect}. Valid: #{legal.join(', ')}"
      end

      values = Array(values).map(&:to_s)
      # Core reads only the first value of a relation's = and !, so a list of ids goes into it.
      values = [values.join(',')] if available[:type] == :relation && %w[= !].include?(operator)
      # Core validates only numeric and date filters; a name here matches nothing and reads as zero.
      values.each { |value| user_ref!(value, field) if value.present? } if user_valued?(field, available)
      query.add_filter(field, operator, values)
    end

    # Core's filters minus those on an excluded custom field, which then reads
    # as unknown everywhere: set, described, or suggested as a close match.
    def available_filters(query)
      query.available_filters.reject { |field, _filter| excluded_custom_field_key?(field) }
    end

    # A saved query may sort or group on an excluded field; its group labels are the field's values.
    def drop_excluded_order!(query)
      query.group_by = nil if excluded_custom_field_key?(query.group_by)
      query.sort_criteria = query.sort_criteria.to_a.reject { |field, _direction| excluded_custom_field_key?(field) }
    end

    def explicit_filters(arguments)
      arguments['filters'].is_a?(Hash) ? arguments['filters'] : {}
    end

    # A named parameter and its own filter would silently replace each other.
    def reject_conflicts!(arguments, explicit)
      self.class::NAMED_FILTERS.each do |name, field|
        next unless arguments[name].present? && explicit.key?(field)

        raise ToolError, "Pass #{name} or filters[#{field.inspect}], not both"
      end
    end

    def apply_explicit_filters!(query, explicit)
      explicit.each do |field, spec|
        operator, values = operator_and_values(spec)
        set_filter!(query, field.to_s, operator, values)
      end
    end

    def operator_and_values(spec)
      return ['=', Array(spec)] unless spec.is_a?(Hash)

      [spec['operator'].presence&.to_s || '=', Array(spec['values'] || '')]
    end

    # --- records named through filters --------------------------------------

    # Reached through `filters`, these would skip the check the named
    # parameters get and answer zero rather than refusing.
    def authorize_filters!(query, explicit, permission)
      explicit.each do |field, spec|
        operator, values = operator_and_values(spec)
        kind = target_kinds(query, field.to_s)[operator]
        next if kind.nil?

        ids_in(values).each { |id| authorize_target!(kind, id, permission) }
      end
    end

    # A version-format custom field names a version, hence a project, whatever
    # the field is called.
    def target_kinds(query, field)
      return self.class::AUTHORISED_FILTERS[field] if self.class::AUTHORISED_FILTERS.key?(field)

      filter = available_filters(query)[field]
      filter && filter[:field]&.field_format == 'version' ? VERSION_FIELD : {}
    end

    # Some filters take a comma separated list inside a single value.
    def ids_in(values)
      Array(values).flat_map { |value| value.to_s.scan(/\d+/) }.uniq
    end

    def authorize_target!(kind, id, permission)
      case kind
      when :project  then authorize!(permission, fetch_project(id))
      when :issue    then authorize!(permission, fetch_issue(id).project)
      when :version  then authorize_owner!(Version.find_by(id: id.to_i), permission)
      when :category then authorize_owner!(IssueCategory.find_by(id: id.to_i), permission)
      end
    end

    # An id matching no record needs no check: it selects nothing either.
    def authorize_owner!(record, permission)
      authorize!(permission, record.project) if record&.project
    end

    # --- sort and group -----------------------------------------------------

    def apply_sort!(query, sort, default:, saved: false)
      if sort.blank?
        # A saved query keeps the order it stores.
        query.sort_criteria = default unless saved
        return
      end

      field, direction = sort.to_s.split(':', 2)
      direction = direction.presence || 'desc'
      legal = sortable_fields(query)

      raise ToolError, "Cannot sort by #{field.inspect}. Sortable: #{legal.join(', ')}" unless legal.include?(field)
      raise ToolError, "sort direction must be asc or desc, got #{direction.inspect}" unless %w[asc desc].include?(direction)

      query.sort_criteria = [[field, direction]]
    end

    def apply_group_by!(query, group_by)
      return if group_by.blank?

      legal = groupable_fields(query)
      raise ToolError, "Cannot group by #{group_by.inspect}. Groupable: #{legal.join(', ')}" unless legal.include?(group_by.to_s)

      query.group_by = group_by.to_s
    end

    def sortable_fields(query)
      query.sortable_columns.select { |name, sortable| sortable.present? && !excluded_custom_field_key?(name) }.keys.sort
    end

    def groupable_fields(query)
      query.groupable_columns.map { |column| column.name.to_s }.reject { |name| excluded_custom_field_key?(name) }.sort
    end

    # --- grouped results ----------------------------------------------------

    # Core keys grouped results by the group's own object and labels them with
    # a view helper a tool cannot reach, so name them here.
    def group_rows(counts, totals = nil)
      Array(counts).map do |value, count|
        row = { group: group_label(value), count: count }
        row[:total_hours] = totals[value] if totals
        row
      end
    end

    def group_label(value)
      case value
      when nil then { id: nil, label: '(none)' }
      # Same rule as core: the id always, the subject only when visible.
      when Issue then { id: value.id, label: value.visible?(user) ? "##{value.id} #{value.subject}" : "##{value.id}" }
      when ActiveRecord::Base then { id: value.id, label: value.respond_to?(:name) ? value.name : value.to_s }
      else { id: nil, label: value.to_s }
      end
    end

    # --- describe -----------------------------------------------------------

    def describe(query, which = true)
      return describe_one(query, which) if which.is_a?(String) && which != 'true'

      {
        filters: available_filters(query).map { |field, filter| describe_filter(field, filter) },
        sortable: sortable_fields(query),
        groupable: groupable_fields(query)
      }
    end

    # One filter by name, the same refusal as a filter that is set.
    def describe_one(query, field)
      filter = available_filters(query)[field]
      unknown_filter!(query, field) if filter.nil?

      describe_filter(field, filter)
    end

    # The refusal names the close filters, so a wrong guess costs one call,
    # not a full describe: a field or label sharing a word with the unknown
    # name, else a spelling match on the field names.
    def unknown_filter!(query, field)
      close = close_filters(query, field)
      if close.empty?
        raise ToolError, "Unknown filter #{field.inspect}. Call with describe: true for the ones this Redmine accepts"
      end

      raise ToolError, "Unknown filter #{field.inspect}. Did you mean #{close.join(', ')}? " \
                       'Call with describe: "<field>" for one filter, or describe: true for all'
    end

    def close_filters(query, field)
      wanted = filter_words(field)
      close  = available_filters(query).select do |name, filter|
        words = filter_words(name) | filter_words(filter[:name])
        words.any? { |word| wanted.any? { |w| word.start_with?(w) || w.start_with?(word) } }
      end.keys
      close = DidYouMean::SpellChecker.new(dictionary: available_filters(query).keys).correct(field.to_s) if close.empty?
      close.first(MAX_SUGGESTIONS)
    end

    # Words of three letters or more, so "id" and "cf" match nothing.
    def filter_words(name)
      name.to_s.downcase.scan(/[a-z0-9]+/).select { |word| word.size >= 3 }
    end

    # redmineup_tags registers its filter type with no operators; its statement
    # takes the list_optional set, so an unregistered type gets that set.
    def operators_for(type)
      Query.operators_by_filter_type[type] || Query.operators_by_filter_type[:list_optional] || []
    end

    def describe_filter(field, filter)
      entry = { field: field, name: filter[:name], type: filter[:type].to_s,
                operators: operators_for(filter[:type]) }
      # Core lists projects as a relation's values, which only its =p operators take.
      entry[:note] = RELATION_NOTE if filter[:type] == :relation

      # Returning early also skips evaluating the values lambda, a query each.
      return entry.merge(values: nil, note: 'Ids come from list_users, or "me".') if user_valued?(field, filter)
      return entry.merge(values: nil, note: 'Ids come from list_projects.')       if PROJECT_FILTERS.include?(field)

      values = Array(filter[:values])
      return entry if values.empty?

      entry.merge(values: values.first(MAX_VALUES).map { |value| labelled(value) },
                  values_truncated: values.size > MAX_VALUES)
    end

    def user_valued?(field, filter)
      USER_FILTERS.include?(field) || filter[:field]&.field_format == 'user'
    end

    # A filter's values are plain strings, or [label, value] pairs.
    def labelled(value)
      label, stored = value.is_a?(Array) ? value : [value, value]
      { value: stored.to_s, label: label.to_s }
    end
  end
end
