# frozen_string_literal: true

require File.expand_path('../test_helper', __dir__)

class RedmineMcpPluginSchemaValidatorTest < ActiveSupport::TestCase
  V = RedmineMcpPlugin::SchemaValidator
  E = RedmineMcpPlugin::ToolError

  SCHEMA = {
    'type' => 'object',
    'properties' => {
      'project' => { 'type' => 'string' },
      'status' => { 'type' => 'string', 'enum' => %w[open closed all] },
      'assigned_to_me' => { 'type' => 'boolean' },
      'limit' => { 'type' => 'integer', 'minimum' => 1 },
      'offset' => { 'type' => 'integer', 'minimum' => 0 }
    },
    'required' => %w[project],
    'additionalProperties' => false
  }.freeze

  def assert_rejected(arguments, expected_fragment)
    error = assert_raises(RedmineMcpPlugin::ToolError) { V.validate!(SCHEMA, arguments) }
    assert_includes error.message, expected_fragment
    error
  end

  def test_accepts_valid_arguments
    assert_nothing_raised do
      V.validate!(SCHEMA, { 'project' => 'x', 'status' => 'closed', 'limit' => 10, 'offset' => 0 })
    end
  end

  def test_missing_required_argument_is_refused
    assert_rejected({}, 'Missing required argument: project')
  end

  # The bug this class exists for. 'Closed' used to fall through to the open
  # branch and return open issues, which is indistinguishable from success.
  def test_enum_is_case_sensitive_and_refuses_near_misses
    assert_rejected({ 'project' => 'x', 'status' => 'Closed' }, 'status must be one of open, closed, all')
    assert_rejected({ 'project' => 'x', 'status' => 'New' }, 'status must be one of')
    assert_rejected({ 'project' => 'x', 'status' => '' }, 'status must be one of')
  end

  def test_enum_accepts_every_declared_value
    %w[open closed all].each do |value|
      assert_nothing_raised { V.validate!(SCHEMA, { 'project' => 'x', 'status' => value }) }
    end
  end

  def test_minimum_is_enforced
    assert_rejected({ 'project' => 'x', 'limit' => 0 }, 'limit must be at least 1')
    assert_rejected({ 'project' => 'x', 'limit' => -5 }, 'limit must be at least 1')
    assert_nothing_raised { V.validate!(SCHEMA, { 'project' => 'x', 'offset' => 0 }) }
  end

  def test_types_are_enforced
    assert_rejected({ 'project' => 'x', 'limit' => 'abc' }, 'limit must be an integer')
    assert_rejected({ 'project' => 'x', 'assigned_to_me' => 'yes' }, 'assigned_to_me must be true or false')
    assert_rejected({ 'project' => 42 }, 'project must be a string')
    assert_rejected({ 'project' => { 'a' => 1 } }, 'an object')
  end

  # Clients assembled out of shell pipelines and templates send everything as a
  # string; refusing those would break callers for no benefit.
  def test_stringified_scalars_are_accepted
    assert_nothing_raised do
      V.validate!(SCHEMA, { 'project' => 'x', 'limit' => '10', 'assigned_to_me' => 'true' })
    end
  end

  def test_unknown_arguments_are_refused_and_the_accepted_set_is_named
    error = assert_rejected({ 'project' => 'x', 'limti' => 5 }, 'Unknown argument: "limti"')
    assert_includes error.message, 'Accepted: assigned_to_me, limit, offset, project, status'
  end

  # A NUL reached the database as a bind parameter and came back as -32603
  # Internal error, which told the caller nothing at all.
  def test_control_characters_are_refused
    assert_rejected({ 'project' => "a\u0000b" }, 'control character')
    assert_rejected({ 'project' => "a\u0007b" }, 'control character')
  end

  def test_whitespace_that_is_legal_in_a_title_survives
    assert_nothing_raised { V.validate!(SCHEMA, { 'project' => "a\tb\nc" }) }
  end

  def test_nil_values_are_left_to_the_tool
    assert_nothing_raised { V.validate!(SCHEMA, { 'project' => 'x', 'status' => nil }) }
  end

  # The project arguments declare %w[string integer]: fetch_project has always
  # taken either an identifier or a numeric id.
  def test_a_list_of_types_accepts_any_of_them
    schema = { 'type' => 'object',
               'properties' => { 'project' => { 'type' => %w[string integer] } },
               'additionalProperties' => false }

    assert_nothing_raised { V.validate!(schema, { 'project' => 'main' }) }
    assert_nothing_raised { V.validate!(schema, { 'project' => 42 }) }
    assert_nothing_raised { V.validate!(schema, { 'project' => '42' }) }

    error = assert_raises(RedmineMcpPlugin::ToolError) { V.validate!(schema, { 'project' => true }) }
    assert_includes error.message, 'must be a string or an integer'
  end

  def test_empty_schema_validates_anything
    assert_nothing_raised { V.validate!(nil, { 'anything' => 1 }) }
    assert_nothing_raised { V.validate!({}, { 'anything' => 1 }) }
  end

  # The string "false" is truthy in Ruby. check_type! accepts it, because
  # clients built out of shell pipelines send booleans as strings, so coerce
  # has to be what stops it reading as true.
  def test_coerce_turns_string_booleans_into_booleans
    coerced = V.coerce(SCHEMA, { 'project' => 'x', 'assigned_to_me' => 'false' })
    assert_equal false, coerced['assigned_to_me']

    coerced = V.coerce(SCHEMA, { 'project' => 'x', 'assigned_to_me' => 'true' })
    assert_equal true, coerced['assigned_to_me']
  end

  def test_coerce_leaves_real_booleans_alone
    coerced = V.coerce(SCHEMA, { 'project' => 'x', 'assigned_to_me' => false })
    assert_equal false, coerced['assigned_to_me']
  end

  def test_coerce_turns_string_integers_into_integers
    coerced = V.coerce(SCHEMA, { 'project' => 'x', 'limit' => '10' })
    assert_equal 10, coerced['limit']
  end

  # project is declared %w[string integer], so there is no single right answer
  # and fetch_project accepts either. Leave it exactly as it arrived.
  def test_coerce_leaves_ambiguous_types_alone
    schema = { 'properties' => { 'project' => { 'type' => %w[string integer] } } }
    assert_equal '42', V.coerce(schema, { 'project' => '42' })['project']
  end

  def test_coerce_preserves_nil_and_unknown_keys
    schema = { 'properties' => { 'limit' => { 'type' => 'integer' } } }
    assert_nil V.coerce(schema, { 'limit' => nil })['limit']
    assert_equal 'kept', V.coerce(schema, { 'other' => 'kept' })['other']
  end

  def test_a_refusal_names_the_type_expected_and_the_shape_received
    schema = { 'properties' => { 'hours' => { 'type' => 'number' }, 'tags' => { 'type' => %w[string integer] },
                                 'flag' => { 'type' => 'boolean' } } }

    assert_equal 'hours must be a number, got an array', assert_raises(E) { V.validate!(schema, { 'hours' => [1] }) }.message
    assert_equal 'tags must be a string or an integer, got an object', assert_raises(E) { V.validate!(schema, { 'tags' => {} }) }.message
    assert_equal 'flag must be true or false, got "yes"', assert_raises(E) { V.validate!(schema, { 'flag' => 'yes' }) }.message
  end

  def test_arrays_and_objects_are_enforced
    schema = { 'properties' => { 'filters' => { 'type' => 'object' }, 'ids' => { 'type' => 'array' } } }

    assert_nothing_raised { V.validate!(schema, { 'filters' => { 'a' => 1 }, 'ids' => [] }) }
    assert_equal 'ids must be an array, got 3', assert_raises(E) { V.validate!(schema, { 'ids' => 3 }) }.message
    assert_equal 'ids must be an array, got an object', assert_raises(E) { V.validate!(schema, { 'ids' => {} }) }.message
    assert_equal 'filters must be an object, got "anything"',
                 assert_raises(E) { V.validate!(schema, { 'filters' => 'anything' }) }.message
    assert_equal 'filters must be an object, got an array', assert_raises(E) { V.validate!(schema, { 'filters' => [] }) }.message
  end

  def test_items_are_checked_one_by_one
    schema = { 'properties' => { 'ids' => { 'type' => 'array', 'items' => { 'type' => %w[integer string] } },
                                 'kinds' => { 'type' => 'array', 'items' => { 'type' => 'string', 'enum' => %w[a b] } } } }

    assert_nothing_raised { V.validate!(schema, { 'ids' => [1, '2', 'me'], 'kinds' => %w[a b] }) }
    assert_equal 'ids[1] must be an integer or a string, got an object',
                 assert_raises(E) { V.validate!(schema, { 'ids' => [1, {}] }) }.message
    assert_equal 'ids[0] must not be null', assert_raises(E) { V.validate!(schema, { 'ids' => [nil] }) }.message
    assert_equal 'kinds[1] must be one of a, b, got "c"', assert_raises(E) { V.validate!(schema, { 'kinds' => %w[a c] }) }.message
    assert_match 'kinds[0] contains a control character',
                 assert_raises(E) { V.validate!(schema, { 'kinds' => ["a\u0000"] }) }.message
  end

  # A type the validator does not know is left to the tool, and named as it is.
  def test_a_type_it_does_not_know_passes_and_is_reported
    schema = { 'properties' => { 'when' => { 'type' => 'timestamp' } } }
    assert_nothing_raised { V.validate!(schema, { 'when' => 3 }) }
    assert_equal 'timestamp', V.name_types(%w[timestamp])
    assert_equal ['when: type timestamp'], V.unsupported(schema)
  end

  # --- what a schema promises and nobody checks --------------------------------

  def test_unsupported_names_every_keyword_that_is_not_enforced
    schema = { 'type' => 'object', 'minProperties' => 1,
               'properties' => {
                 'limit' => { 'type' => 'integer', 'minimum' => 1, 'maximum' => 10, 'description' => 'ok', 'format' => 'int32' },
                 'tags' => { 'type' => 'array', 'items' => { 'type' => 'string', 'pattern' => 'x', 'enum' => %w[a] } },
                 'kind' => { 'type' => %w[string decimal] },
                 'ids' => { 'type' => 'array', 'items' => { 'type' => 'uuid' } }
               } }

    assert_equal ['schema: minProperties', 'limit: maximum', 'tags: items.pattern', 'kind: type decimal', 'ids: items: type uuid'],
                 V.unsupported(schema)
    assert_equal [], V.unsupported(SCHEMA)
    assert_equal [], V.unsupported(nil)
  end

  # The schema served to clients is a promise. Every built-in tool may only
  # declare what this file enforces, and an array says what it holds.
  def test_no_built_in_tool_declares_what_is_not_enforced
    built_in = RedmineMcpPlugin::Registry.all
    built_in.each do |tool|
      schema     = tool.mcp_schema
      properties = schema['properties'] || {}

      assert_equal [], V.unsupported(schema), tool.mcp_name
      assert_equal 'object', schema['type'], tool.mcp_name
      assert_equal false, schema['additionalProperties'], "#{tool.mcp_name} must refuse unknown arguments"
      assert_empty Array(schema['required']) - properties.keys, "#{tool.mcp_name} requires an argument it does not declare"
      properties.each do |name, spec|
        assert spec['type'].present?, "#{tool.mcp_name}.#{name} declares no type"
        next unless Array(spec['type']).include?('array')

        assert spec['items'].present?, "#{tool.mcp_name}.#{name} is an array and does not say of what"
      end
    end
  end

  def test_numbers_are_recognised_and_coerced
    schema = { 'properties' => { 'hours' => { 'type' => 'number', 'minimum' => 0.5 } } }

    assert_equal 1.5, V.coerce(schema, { 'hours' => '1.5' })['hours']
    assert_equal 2, V.coerce(schema, { 'hours' => 2 })['hours']
    assert_equal 'soon', V.coerce(schema, { 'hours' => 'soon' })['hours']
    assert_match 'hours must be at least 0.5', assert_raises(E) { V.validate!(schema, { 'hours' => '0.25' }) }.message
  end

  def test_required_accepts_false_and_zero_and_refuses_blank
    schema = { 'properties' => { 'flag' => { 'type' => 'boolean' }, 'count' => { 'type' => 'integer' },
                                 'name' => { 'type' => 'string' } }, 'required' => %w[flag count name] }

    assert_nothing_raised { V.validate!(schema, { 'flag' => false, 'count' => 0, 'name' => 'x' }) }
    assert_equal 'Missing required arguments: flag, name',
                 assert_raises(E) { V.validate!(schema, { 'count' => 0, 'name' => ' ' }) }.message
  end
end
