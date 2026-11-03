require_relative "test_helper"

# `agentcat_session_id_source` / `agentcat_agent_id_source` on the wire tags, so a user
# can tell from the dashboard why a session or actor came out the way it did instead of
# having to dig through logs or source.
class DiagnosticTagsTest < Minitest::Test
  include AgentCatTestHelpers

  def source_tag_of(event, name)
    event[:tags]["agentcat_#{name}_source"]
  end

  def test_minted_session_source
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "minted", source_tag_of(client.last_event, "session_id")
  end

  def test_supplied_session_source
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    session_id = AgentCat::SessionManager.mint_session_id

    tool_result(server, "echo", {msg: "hello", session_id: session_id})

    assert_equal "supplied", source_tag_of(client.last_event, "session_id")
  end

  def test_invalid_session_source
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    # Goes through the ToolHandle directly: a malformed session_id now fails the schema
    # `pattern` before Interceptor#resolve_session's :invalid branch runs on the standard
    # tools/call path (see test_sessions.rb for the pair of tests dedicated to that).
    server.tools["echo"].call(msg: "hello", session_id: "not-a-real-id")
    AgentCat.flush(timeout: 1)

    assert_equal "invalid", source_tag_of(client.last_event, "session_id")
  end

  def test_hook_session_source
    server = build_server
    resolver = ->(*) { "chat-12345" }
    client = track(server, project_id: PROJECT_ID, resolve_session_id: resolver)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "hook", source_tag_of(client.last_event, "session_id")
  end

  def test_stateless_session_source
    server = build_server
    client = track(server, project_id: PROJECT_ID, stateless: true)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "stateless", source_tag_of(client.last_event, "session_id")
  end

  def test_foreign_session_source
    owner = MCP::Tool.define(name: "owner", input_schema: {type: "object", properties: {session_id: {type: "string"}}, required: ["session_id"]}) do |server_context: nil, **arguments|
      MCP::Tool::Response.new([{type: "text", text: arguments.fetch(:session_id)}])
    end
    server = build_server(tools: [owner])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "owner", {session_id: "host-owned"})

    assert_equal "foreign", source_tag_of(client.last_event, "session_id")
  end

  def test_identified_actor_source
    server = build_server
    identify = ->(*) { AgentCat::UserIdentity.new(user_id: "user-1") }
    client = track(server, project_id: PROJECT_ID, identify: identify, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "agent-1"})

    assert_equal "identified", source_tag_of(client.last_event, "agent_id")
  end

  def test_supplied_actor_source
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "agent-1"})

    assert_equal "supplied", source_tag_of(client.last_event, "agent_id")
  end

  def test_foreign_actor_source
    owner = MCP::Tool.define(name: "owner", input_schema: {type: "object", properties: {agent_id: {type: "string"}}, required: ["agent_id"]}) do |server_context: nil, **arguments|
      MCP::Tool::Response.new([{type: "text", text: arguments.fetch(:agent_id)}])
    end
    server = build_server(tools: [owner])
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "owner", {agent_id: "host-owned"})

    assert_equal "foreign", source_tag_of(client.last_event, "agent_id")
  end

  def test_no_actor_source_when_agent_tracking_is_off_and_no_identify
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hello"})

    assert_nil source_tag_of(client.last_event, "agent_id")
  end

  def test_no_actor_source_when_agent_tracking_is_on_but_agent_id_not_sent
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello"})

    assert_nil source_tag_of(client.last_event, "agent_id")
  end

  # The value itself rides as `agentcat_agent_id`, next to its source — same tag as the
  # Go/TS SDKs, so the dashboard can group calls per agent.
  def test_supplied_agent_id_is_tagged
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "opus-4.80-1m|claude-code|k3n9x"})

    assert_equal "opus-4.80-1m|claude-code|k3n9x", client.last_event[:tags]["agentcat_agent_id"]
  end

  # With `identify` the actor is the human, but which agent made the call still matters.
  def test_agent_id_is_tagged_alongside_identify
    server = build_server
    identify = ->(*) { AgentCat::UserIdentity.new(user_id: "user-1") }
    client = track(server, project_id: PROJECT_ID, identify: identify, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "agent-1"})

    assert_equal "user-1", client.last_event[:actor_id]
    assert_equal "agent-1", client.last_event[:tags]["agentcat_agent_id"]
  end

  # SDK tags skip customer tag validation, so the tag copy is clamped: CR/LF become
  # spaces and it's cut at 200 characters.
  def test_agent_id_tag_is_clamped
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "a\r\nb" + "x" * 300})

    tag = client.last_event[:tags]["agentcat_agent_id"]
    assert_equal 200, tag.length
    assert tag.start_with?("a  bx")
  end

  def test_no_agent_id_tag_when_tracking_is_off_or_agent_id_is_blank
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)
    tool_result(server, "echo", {msg: "hello", agent_id: "  "})
    refute client.last_event[:tags]&.key?("agentcat_agent_id")

    other = build_server
    off = track(other, project_id: PROJECT_ID)
    tool_result(other, "echo", {msg: "hello"})
    refute off.last_event[:tags]&.key?("agentcat_agent_id")
  end

  # A tool that declares its own `agent_id` owns it; AgentCat doesn't read it, so it
  # must not tag it either.
  def test_no_agent_id_tag_for_a_tool_owned_agent_id
    owner = MCP::Tool.define(name: "owner", input_schema: {type: "object", properties: {agent_id: {type: "string"}}, required: ["agent_id"]}) do |server_context: nil, **arguments|
      MCP::Tool::Response.new([{type: "text", text: arguments.fetch(:agent_id)}])
    end
    server = build_server(tools: [owner])
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "owner", {agent_id: "host-owned"})

    refute client.last_event[:tags].key?("agentcat_agent_id")
  end
end
