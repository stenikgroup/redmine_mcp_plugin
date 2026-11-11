# frozen_string_literal: true

module RedmineMcpPlugin
  class Tool
    # Custom fields in a read or a write: the values a caller may see, minus the
    # ones an administrator excludes, and the values a write accepts.
    module CustomFields
      # Choices named in a refusal, capped so a user field on a big instance stays readable.
      MAX_CHOICES = 25

      # Every custom field in a filter, sort or group key: own, reached through an
      # association, or the head of a chained filter on a version or user field:
      # cf_12, issue.cf_12, project.cf_12, cf_12.status, cf_12.cf_14.
      CUSTOM_FIELD_KEY = /(?:\A|\.)cf_(\d+)(?=\.|\z)/

      # The formats that store a record id as their value. A list field stores
      # the label itself, so it gets none.
      LABELLED_FORMATS = %w[enumeration user version].freeze

      # Appended to the description of every tool that returns custom fields.
      CUSTOM_FIELD_LABELS = 'Each custom field gives its format; one stored as an id (enumeration, user, version) ' \
                            'also names it in label, null for a target the caller may not see or that was deleted.'

      private

      # The fields an administrator keeps away from every MCP client, read once per call.
      def excluded_custom_field_ids
        @excluded_custom_field_ids ||= Settings.excluded_custom_field_ids.to_set
      end

      def excluded_custom_field?(id)
        excluded_custom_field_ids.include?(id.to_i)
      end

      # Any excluded field in the key makes it excluded: cf_12.cf_14 reads both.
      def excluded_custom_field_key?(key)
        key.to_s.scan(CUSTOM_FIELD_KEY).flatten.any? { |id| excluded_custom_field?(id) }
      end

      # Core's visible or editable values, minus the excluded fields. Every
      # custom field a tool reads or offers goes through here.
      def shown_custom_field_values(values)
        values.reject { |value| excluded_custom_field?(value.custom_field_id) }
      end

      def shown_custom_fields(values)
        custom_field_value_rows(shown_custom_field_values(values))
      end

      # The custom fields this user may set on `record`, each with its allowed
      # values, in one shape for issues and time entries. `required_ids` adds the
      # fields a workflow rule requires here beyond the definition flag.
      def custom_field_rows(record, required_ids = [])
        shown_custom_field_values(record.editable_custom_field_values(user)).map do |value|
          field = value.custom_field
          {
            id: field.id,
            name: field.name,
            format: field.field_format,
            required: custom_field_required?(field, required_ids),
            multiple: field.multiple?,
            # True for a long text field with text formatting on: its value takes markup.
            rendered: field.full_text_formatting?,
            default_value: field.default_value,
            possible_values: possible_values_for(field, record)
          }
        end
      end

      def custom_field_required?(field, required_ids)
        field.is_required? || required_ids.include?(field.id.to_s)
      end

      # Core gives plain strings for a list field, and [label, value] pairs for
      # the formats stored as ids and for bool. Empty for a free-form format.
      # A user field opens with core's "<< me >>" shortcut for the caller, who is
      # listed again by name: one row per value, the named one.
      def possible_values_for(field, record)
        rows = field.possible_values_options(record).map do |option|
          label, value = option.is_a?(Array) ? option : [option, option]
          { value: value.to_s, label: label.to_s }
        end
        rows.reverse.uniq { |row| row[:value] }.reverse
      end

      # Same reason as the attributes: core keeps only the custom fields this user may edit here.
      # A refused field is named only when the caller may read it on this record;
      # any other id stays a number, so a refusal names no excluded, other-type
      # or role-restricted field.
      def unknown_custom_fields(record, ids)
        editable = shown_custom_field_values(record.editable_custom_field_values(user)).map { |value| value.custom_field_id.to_s }
        unknown  = Array(ids).map(&:to_s) - editable
        return nil if unknown.empty?

        names = shown_custom_field_values(record.visible_custom_field_values(user))
                .to_h { |value| [value.custom_field_id.to_s, value.custom_field.name] }
        unknown.map { |id| names[id] || "id #{id}" }.join(', ')
      end

      # The values to assign, by field id: refused by name when the field cannot
      # be set here, and checked against the field's allowed values before the
      # save, so a wrong one is refused with the choices instead of core's "is
      # not included in the list". A label is accepted when it names one value.
      def custom_field_values_for(record, raw)
        values = custom_field_values_from(raw)
        return nil if values.nil?

        list = unknown_custom_fields(record, values.keys)
        raise ToolError, "#{list} cannot be set here" if list

        values.to_h do |id, value|
          field   = record.custom_field_values.detect { |v| v.custom_field_id.to_s == id }.custom_field
          options = possible_values_for(field, record)
          next [id, value] if options.empty?

          # Core still accepts the value already stored, though no longer offered.
          kept     = Array(record.custom_field_value(field)).map(&:to_s)
          resolved = Array(value).map { |one| kept.include?(one) ? one : resolve_custom_value(field, options, one) }
          [id, value.is_a?(Array) ? resolved : resolved.first]
        end
      end

      def resolve_custom_value(field, options, value)
        value = value.to_s
        return value if value.blank?

        value = user.id.to_s if field.field_format == 'user' && value == 'me'
        value = { 'true' => '1', 'false' => '0' }.fetch(value.downcase, value) if field.field_format == 'bool'
        return value if options.any? { |option| option[:value] == value }

        matches = options.select { |option| option[:label].casecmp?(value) }.map { |option| option[:value] }.uniq
        return matches.first if matches.size == 1
        if matches.size > 1
          raise ToolError, "#{custom_field_label(field)}: #{value.inspect} names several values, pass one: #{matches.join(', ')}"
        end

        raise ToolError, "#{custom_field_label(field)} has no value #{value.inspect}; accepts #{choices_text(options)}"
      end

      # The required custom fields a save would refuse blank, named with their
      # choices before core's bare "cannot be blank". Runs once the attributes
      # are assigned and before the save, since core reads the workflow rules of
      # the status being set, not the stored one. Core checks a field a workflow
      # requires at every save; a field required by its own flag on a new record,
      # and on a stored one once a custom field changes, which a tracker move
      # counts as. An update that changes none of that is left to core, as core
      # leaves it alone too.
      def require_custom_fields!(record, required_ids = [])
        changed = record.new_record? || record.custom_field_values_changed?
        missing = shown_custom_field_values(record.editable_custom_field_values(user)).select do |current|
          field = current.custom_field
          next false unless Array(current.value).all?(&:blank?)

          required_ids.include?(field.id.to_s) || (changed && field.is_required?)
        end
        return if missing.empty?

        raise ToolError, missing.map { |current| required_text(current.custom_field, record) }.join('; ')
      end

      def required_text(field, record)
        options = possible_values_for(field, record)
        text    = "#{custom_field_label(field)} is required"
        options.empty? ? text : "#{text}; accepts #{choices_text(options)}"
      end

      def custom_field_label(field)
        "custom field #{field.name} (id #{field.id})"
      end

      # A list field repeats its value as the label; the other formats show both.
      def choices_text(options)
        shown = options.first(MAX_CHOICES).map do |option|
          option[:value] == option[:label] ? option[:value].inspect : "#{option[:value]} (#{option[:label]})"
        end
        text = shown.join(', ')
        options.size > MAX_CHOICES ? "#{text}, and #{options.size - MAX_CHOICES} more" : text
      end

      def saved_custom_fields(record, ids)
        values = Array(ids).filter_map do |id|
          record.custom_field_values.detect { |v| v.custom_field_id.to_s == id.to_s }
        end
        shown_custom_fields(values)
      end

      # Rows for any number of custom field values, from one record or a page of
      # them, with the labels looked up in one query per format.
      def custom_field_value_rows(values)
        labels = custom_value_labels(values)
        values.map { |value| custom_field_row(value, labels) }
      end

      # Core keeps an empty multiple field as [nil]; its API leaves blank values out, and so does this.
      # `value` stays the stored id, as the write tools take it; `label` names it.
      def custom_field_row(value, labels)
        field = value.custom_field
        shown = value.value.is_a?(Array) ? value.value.reject(&:blank?) : value.value
        row   = { id: field.id, name: field.name, format: field.field_format, value: shown }
        return row unless LABELLED_FORMATS.include?(field.field_format)

        label = ->(id) { labels[[field.id, id.to_s]] }
        row[:label] = shown.is_a?(Array) ? shown.map(&label) : (label.call(shown) if shown.present?)
        row
      end

      # Labels keyed by [custom field id, stored id].
      def custom_value_labels(values)
        wanted = values.flat_map do |value|
          format = value.custom_field.field_format
          next [] unless LABELLED_FORMATS.include?(format)

          Array(value.value).reject(&:blank?).map { |id| [format, value.custom_field_id, id.to_s] }
        end
        custom_value_names_by_format(wanted)
      end

      # `wanted` lists [format, custom field id, stored id]; one query per format.
      def custom_value_names_by_format(wanted)
        wanted.uniq.group_by(&:first).each_with_object({}) do |(format, group), labels|
          labels.merge!(custom_value_names(format, group.map { |_, field_id, id| [field_id, id] }))
        end
      end

      # A user the caller may not see, as list_users applies it, and a version
      # whose issues they may not see stay unnamed, as does a target deleted
      # since: the pair maps to nil. An enumeration is the field's own, inactive
      # ones included, as core still shows a value it no longer offers.
      def custom_value_names(format, pairs)
        ids = pairs.map(&:last).uniq
        if format == 'enumeration'
          return CustomFieldEnumeration.where(id: ids, custom_field_id: pairs.map(&:first).uniq)
                                       .pluck(:custom_field_id, :id, :name)
                                       .to_h { |field_id, id, name| [[field_id, id.to_s], name] }
        end

        scope = format == 'user' ? User.visible(user) : Version.visible(user)
        names = scope.where(id: ids).to_h { |record| [record.id.to_s, record.name] }
        pairs.index_with { |pair| names[pair.last] }
      end

      # SchemaValidator does not walk into an object, so the shape is checked here.
      def custom_field_values_from(raw)
        return nil if raw.blank?
        raise InvalidArgument, 'custom_field_values must be an object keyed by numeric custom field id' unless raw.is_a?(Hash)

        raw.each_with_object({}) do |(id, value), out|
          raise InvalidArgument, "custom_field_values key #{id.inspect} is not a numeric custom field id" unless /\A\d+\z/.match?(id.to_s)
          raise InvalidArgument, "custom_field_values[#{id}] must be a string, a number, or an array of them" if value.is_a?(Hash)

          out[id.to_s] = value.is_a?(Array) ? value.map(&:to_s) : value.to_s
        end
      end

      def custom_field_ids(arguments)
        arguments['custom_field_values'].is_a?(Hash) ? arguments['custom_field_values'].keys : []
      end
    end
  end
end
