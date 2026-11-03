require_relative "test_helper"

class ToolHandleTest < Minitest::Test
  def build_handle(**overrides)
    defaults = {name: "t", description: "A tool", call_fn: ->(arguments, server_context) { [arguments, server_context] }}
    AgentCat::ToolHandle.new(**defaults, **overrides)
  end

  def test_add_input_parameter_keeps_hash_schemas_as_hashes
    handle = build_handle(input_schema: {"type" => "object", "properties" => {"msg" => {"type" => "string"}}})

    handle.add_input_parameter("context", description: "why")
    handle.add_input_parameter(:context, description: "ignored")

    assert_kind_of Hash, handle.input_schema
    assert_equal({type: "string", description: "why"}, handle.input_schema[:properties][:context])
    assert_equal({type: "string"}, handle.input_schema[:properties][:msg])
    assert handle.input_parameter?("context")
    refute handle.input_parameter?("session_id")
  end

  def test_add_input_parameter_rebuilds_mcp_input_schemas
    handle = build_handle(input_schema: MCP::Tool::InputSchema.new(type: "object", properties: {msg: {type: "string"}}))

    handle.add_input_parameter("session_id", description: "sid")

    assert_kind_of MCP::Tool::InputSchema, handle.input_schema
    assert_equal({type: "string", description: "sid"}, handle.to_h[:inputSchema][:properties][:session_id])
    refute handle.input_schema.missing_required_arguments?({msg: "x"})
  end

  def test_to_h_matches_the_mcp_tool_shape
    handle = build_handle(title: "T", input_schema: {type: "object", properties: {}}, output_schema: {type: "object"}, meta: {a: 1})

    assert_equal({name: "t", title: "T", description: "A tool", inputSchema: {type: "object", properties: {}}, outputSchema: {type: "object"}, _meta: {a: 1}}, handle.to_h)
  end

  def test_call_without_interceptor_hands_string_keyed_arguments_to_call_fn
    handle = build_handle

    assert_equal [{"msg" => "hi"}, :ctx], handle.call(msg: "hi", server_context: :ctx)
    assert_equal [{"msg" => "hi"}, nil], handle.call({msg: "hi"})
    assert_equal [{}, nil], handle.call
  end

  def test_interceptor_receives_arguments_context_and_the_original
    handle = build_handle
    seen = nil
    handle.intercept do |arguments, server_context, original|
      seen = [arguments, server_context]
      original.call(arguments.merge("added" => true), server_context)
    end

    assert handle.intercepted?
    assert_equal [{"msg" => "hi", "added" => true}, :ctx], handle.call({"msg" => "hi"}, server_context: :ctx)
    assert_equal [{"msg" => "hi"}, :ctx], seen
  end
end
