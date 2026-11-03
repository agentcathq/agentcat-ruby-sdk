require_relative "test_helper"

# `enable_tracing`, `enable_tool_call_context` and `custom_context_description` — same
# switches as the Go/TS/Python SDKs.
class TracingAndContextOptionsTest < Minitest::Test
  include AgentCatTestHelpers

  def test_tracing_off_injects_no_handles_but_keeps_context
    server = build_server
    track(server, enable_tracing: false, enable_agent_tracking: true)

    schema = listed_tool(server, "echo")[:inputSchema]

    assert_equal %i[msg context], schema[:properties].keys
    assert_equal %w[msg context], schema[:required]
  end

  def test_tracing_off_runs_the_tool_without_an_event_or_mint_back
    server = build_server
    identify_calls = 0
    identify = ->(*) {
      identify_calls += 1
      nil
    }
    client = track(server, project_id: PROJECT_ID, enable_tracing: false, identify: identify)

    # `echo` only takes `msg:`, so this also proves `context` got stripped first.
    result = tool_result(server, "echo", {msg: "hi", context: "why"})

    assert_equal ["hi"], texts_of(result)
    refute result.key?(:structuredContent)
    assert_empty client.events
    assert_equal 0, identify_calls
  end

  def test_tracing_off_drops_custom_events_for_the_server
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_tracing: false)

    AgentCat.publish_custom_event(server, PROJECT_ID, resource_name: "checkout")
    AgentCat.flush(timeout: 1)

    assert_empty client.events
  end

  def test_tracing_off_still_answers_get_more_tools
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_tracing: false)

    result = tool_result(server, "get_more_tools", {context: "I wanted a translate tool"})

    assert_equal [AgentCat::Schema::GET_MORE_TOOLS_PROMPT], texts_of(result)
    assert_empty client.events
  end

  def test_context_off_leaves_context_out_of_the_schema
    server = build_server
    track(server, enable_tool_call_context: false)

    schema = listed_tool(server, "echo")[:inputSchema]

    assert_equal %i[msg session_id], schema[:properties].keys
    assert_equal %w[msg session_id], schema[:required]
  end

  def test_context_off_publishes_without_intent
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_tool_call_context: false)

    tool_result(server, "echo", {msg: "hi"})

    assert_nil client.last_event[:user_intent]
    assert_equal false, client.last_event[:properties]["agentcat_context_supplied"]
  end

  # `get_more_tools` is useless without its context, so the flag doesn't touch it.
  def test_context_off_keeps_get_more_tools_context
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_tool_call_context: false)

    assert_includes listed_tool(server, "get_more_tools")[:inputSchema][:required], "context"

    tool_result(server, "get_more_tools", {context: "I wanted a translate tool"})

    assert_equal "I wanted a translate tool", client.last_event[:user_intent]
  end

  def test_custom_context_description_replaces_the_default
    server = build_server
    track(server, custom_context_description: "Which customer ticket is this for?")

    properties = listed_tool(server, "echo")[:inputSchema][:properties]

    assert_equal "Which customer ticket is this for?", properties.dig(:context, :description)
    # get_more_tools keeps its own description.
    refute_equal "Which customer ticket is this for?",
      listed_tool(server, "get_more_tools").dig(:inputSchema, :properties, :context, :description)
  end

  def test_blank_custom_context_description_falls_back_to_the_default
    server = build_server
    track(server, custom_context_description: "  ")

    properties = listed_tool(server, "echo")[:inputSchema][:properties]

    assert_equal AgentCat::Schema::CONTEXT_DESCRIPTION, properties.dig(:context, :description)
  end
end
