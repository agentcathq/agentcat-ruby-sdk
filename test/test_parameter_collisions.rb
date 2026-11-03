require_relative "test_helper"

# A tool that already declares `session_id`, `agent_id` or `context` keeps it: AgentCat
# does not inject its own copy, does not read the value and does not strip it from the
# call, so the host's argument arrives at the host's handler unchanged.
class ParameterCollisionsTest < Minitest::Test
  include AgentCatTestHelpers

  def owning_tool(parameter, name: "owner", description: "The tool's own parameter")
    schema = {type: "object", properties: {parameter => {type: "string", description: description}}, required: [parameter.to_s]}
    MCP::Tool.define(name: name, description: "Owns #{parameter}", input_schema: schema) do |server_context: nil, **arguments|
      MCP::Tool::Response.new([{type: "text", text: arguments.fetch(parameter)}])
    end
  end

  def test_tool_owned_session_id_reaches_the_handler
    server = build_server(tools: [owning_tool(:session_id)])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "owner", {session_id: "host-owned-value"})

    assert_equal ["host-owned-value"], texts_of(result)
    assert_nil client.last_event.fetch(:session_id)
    assert_equal "host-owned-value", client.last_event[:parameters]["arguments"]["session_id"]
  end

  def test_tool_owned_session_id_gets_no_mint_back
    server = build_server(tools: [owning_tool(:session_id)])
    track(server, project_id: PROJECT_ID)

    result = tool_result(server, "owner", {session_id: "host-owned-value"})

    refute result.key?(:_meta)
    assert_equal ["host-owned-value"], texts_of(result)
  end

  def test_tool_owned_parameter_keeps_its_own_schema
    server = build_server(tools: [owning_tool(:session_id)])
    track(server, project_id: PROJECT_ID)

    property = listed_tool(server, "owner")[:inputSchema][:properties][:session_id]

    assert_equal "The tool's own parameter", property[:description]
  end

  def test_tool_owned_agent_id_is_not_reported_as_the_actor
    server = build_server(tools: [owning_tool(:agent_id)])
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    result = tool_result(server, "owner", {agent_id: "host-owned-agent"})

    # session_id is still ours on this tool, so the mint-back text precedes the tool's own.
    assert_equal "host-owned-agent", texts_of(result).last
    assert_nil client.last_event[:actor_id]
  end

  def test_tool_owned_context_is_not_reported_as_user_intent
    server = build_server(tools: [owning_tool(:context)])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "owner", {context: "a document to summarise"})

    assert_equal "a document to summarise", texts_of(result).last
    assert_nil client.last_event[:user_intent]
    assert_equal false, client.last_event[:properties]["agentcat_context_supplied"]
  end

  def test_other_tools_on_the_same_server_are_unaffected
    server = build_server(tools: [owning_tool(:session_id), echo_tool])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello", context: "checking the echo tool"})
    meta = agentcat_meta(result)

    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal "checking the echo tool", client.last_event[:user_intent]
    assert listed_tool(server, "echo")[:inputSchema][:properties].key?(:session_id)
  end

  def test_collision_is_logged_once_per_tool_and_parameter
    log = StringIO.new
    with_logger(Logger.new(log, level: Logger::WARN)) do
      server = build_server(tools: [owning_tool(:session_id), owning_tool(:context, name: "other")])
      track(server, project_id: PROJECT_ID)
      # A second track() on the same server must not re-report what is already instrumented.
      track(server, project_id: PROJECT_ID)
    end

    assert_equal 1, log.string.scan(/"owner".*"session_id"/).size
    assert_equal 1, log.string.scan(/"other".*"context"/).size
    assert_match(/ERROR.*"session_id"/, log.string)
    assert_match(/WARN.*"context"/, log.string)
  end

  # `oneOf`/`allOf`/`anyOf` have no defined meaning for a sibling `properties`, so
  # injection is skipped wholesale rather than guessed at - matches the Python SDK.
  def test_composed_input_schema_gets_no_injection_at_all
    composed_tool = MCP::Tool.define(
      name: "composed",
      description: "oneOf-shaped input",
      input_schema: {
        oneOf: [
          {type: "object", properties: {a: {type: "string"}}, required: ["a"]},
          {type: "object", properties: {b: {type: "string"}}, required: ["b"]}
        ]
      }
    ) { |server_context: nil, **arguments| MCP::Tool::Response.new([{type: "text", text: arguments.keys.join(",")}]) }
    server = build_server(tools: [composed_tool])
    client = track(server, project_id: PROJECT_ID)

    listed = listed_tool(server, "composed")
    refute listed[:inputSchema].key?(:properties)

    result = tool_result(server, "composed", {a: "value"})

    assert_equal ["a"], texts_of(result)
    refute result.key?(:_meta)
    assert_nil client.last_event.fetch(:session_id)
    assert_equal "foreign", client.last_event[:tags]["agentcat_session_id_source"]
  end

  def test_host_defined_get_more_tools_keeps_its_own_context
    custom = owning_tool(:context, name: "get_more_tools")
    server = build_server(tools: [custom])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "get_more_tools", {context: "the host's own meaning"})

    assert_equal "the host's own meaning", texts_of(result).last
    assert_nil client.last_event[:user_intent]
  end

  private

  def with_logger(logger)
    previous = AgentCat.logger
    AgentCat.logger = logger
    yield
  ensure
    AgentCat.logger = previous
  end
end
