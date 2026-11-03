require_relative "test_helper"

class GetMoreToolsTest < Minitest::Test
  include AgentCatTestHelpers

  def test_is_registered_with_a_description_and_required_context
    server = build_server
    track(server)

    listed = listed_tool(server, "get_more_tools")

    assert_equal AgentCat::Schema::GET_MORE_TOOLS_DESCRIPTION, listed[:description]
    assert_equal ["context", "session_id"], listed[:inputSchema][:required]
    assert listed[:inputSchema][:properties].key?(:session_id)
  end

  def test_is_marked_read_only
    server = build_server
    track(server)

    assert_equal true, listed_tool(server, "get_more_tools").dig(:annotations, :readOnlyHint)
  end

  def test_returns_the_prompt
    server = build_server
    track(server)

    result = tool_result(server, "get_more_tools", {context: "I wanted a translate tool"})

    assert_equal AgentCat::Schema::GET_MORE_TOOLS_PROMPT, texts_of(result).last
  end

  def test_calls_are_reported_like_any_other_tool
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "get_more_tools", {context: "I wanted a translate tool"})

    assert_equal "get_more_tools", client.last_event[:resource_name]
    assert_equal "I wanted a translate tool", client.last_event[:user_intent]
    assert AgentCat::SessionManager.valid?(client.last_event[:session_id])
  end

  def test_requires_context
    server = build_server
    track(server)

    result = tool_result(server, "get_more_tools", {})

    assert result[:isError]
  end

  def test_does_not_replace_a_host_defined_get_more_tools
    custom = MCP::Tool.define(name: "get_more_tools", description: "Mine", input_schema: {type: "object", properties: {}}) { |**| MCP::Tool::Response.new([{type: "text", text: "custom"}]) }
    server = build_server(tools: [custom])
    track(server)

    assert_equal "Mine", listed_tool(server, "get_more_tools")[:description]
    assert_equal 1, list_tools(server).count { |tool| tool[:name] == "get_more_tools" }
    assert_equal "custom", texts_of(tool_result(server, "get_more_tools", {})).last
  end

  def test_enable_report_missing_false_skips_registration
    server = build_server
    track(server, enable_report_missing: false)

    refute listed_tool(server, "get_more_tools")
    assert_equal 1, list_tools(server).size
  end

  def test_enable_report_missing_false_still_keeps_a_host_defined_one
    custom = MCP::Tool.define(name: "get_more_tools", description: "Mine", input_schema: {type: "object", properties: {}}) { |**| MCP::Tool::Response.new([{type: "text", text: "custom"}]) }
    server = build_server(tools: [custom])
    track(server, enable_report_missing: false)

    assert_equal "Mine", listed_tool(server, "get_more_tools")[:description]
  end
end
