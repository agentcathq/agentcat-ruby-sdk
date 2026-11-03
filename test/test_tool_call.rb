require_relative "test_helper"

# The hooks that see a call get one frozen `AgentCat::ToolCall`, built
# on the request thread before any hook runs.
class ToolCallTest < Minitest::Test
  include AgentCatTestHelpers

  HOOKS = %i[identify resolve_session_id event_tags event_properties].freeze

  def test_each_of_the_four_hooks_gets_a_tool_call
    seen = {}
    hooks = HOOKS.to_h do |name|
      [name, ->(tool_call) {
        seen[name] = tool_call
        nil
      }]
    end
    server = build_server
    track(server, project_id: PROJECT_ID, **hooks)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal HOOKS.sort, seen.keys.sort
    seen.each_value do |tool_call|
      assert_instance_of AgentCat::ToolCall, tool_call
      assert_equal "echo", tool_call.tool_name
      assert_equal "hello", tool_call.arguments["msg"]
    end
    # One snapshot per call, shared by every hook.
    assert_equal 1, seen.values.map(&:object_id).uniq.size
  end

  # The raw arguments, including the parameters AgentCat injects.
  def test_arguments_include_the_injected_parameters
    seen = nil
    server = build_server
    track(server, project_id: PROJECT_ID, enable_agent_tracking: true, event_tags: ->(tool_call) {
      seen = tool_call
      {}
    })

    tool_result(server, "echo", {msg: "hi", session_id: "start", agent_id: "agent-1", context: "why"})

    assert_equal({"msg" => "hi", "session_id" => "start", "agent_id" => "agent-1", "context" => "why"}, seen.arguments)
  end

  def test_mutating_the_arguments_raises_in_the_hook_and_changes_nothing
    received = nil
    tool = echo_tool(input_schema: {type: "object", properties: {msg: {type: "string"}, nested: {type: "object"}}, required: ["msg"]}) do |msg:, nested: nil, **|
      received = {msg: msg, nested: nested}
      MCP::Tool::Response.new([{type: "text", text: msg}])
    end
    errors = []
    mutate = ->(tool_call) {
      [
        -> { tool_call.arguments["msg"] = "changed" },
        -> { tool_call.arguments["msg"] << "!" },
        -> { tool_call.arguments["nested"]["list"] << 4 },
        -> { tool_call.arguments["nested"]["key"] = "changed" },
        -> { tool_call.meta["extra"] = 1 },
        -> { tool_call.headers["x"] = "y" },
        -> { tool_call.instance_variable_set(:@tool_name, "other") }
      ].each do |attempt|
        attempt.call
      rescue FrozenError => e
        errors << e
      end
      raise FrozenError, "the last one escapes"
    }
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID, identify: mutate, event_tags: mutate)

    log = capture_log { tool_result(server, "echo", {msg: "hello", nested: {"list" => [1, 2, 3], "key" => "v"}}) }

    assert_equal 14, errors.size
    assert_equal "hello", received[:msg]
    assert_equal({"list" => [1, 2, 3], "key" => "v"}, received[:nested])
    arguments = client.last_event[:parameters]["arguments"]
    assert_equal "hello", arguments["msg"]
    assert_equal({"list" => [1, 2, 3], "key" => "v"}, arguments["nested"])
    assert_match(/WARN: identify hook raised FrozenError/, log)
    assert_match(/WARN: event_tags hook raised FrozenError/, log)
  end

  # The hook thread cannot read the request's fiber-local headers, so the ToolCall
  # carries them from the request thread.
  def test_identify_sees_the_http_headers_of_the_request
    seen = nil
    server = build_server
    track(server, project_id: PROJECT_ID, identify: ->(tool_call) {
      seen = tool_call
      AgentCat::UserIdentity.new(user_id: tool_call.headers.fetch("x-user"))
    })
    env = {"HTTP_X_USER" => "ann", "HTTP_MCP_SESSION_ID" => "sess-1", "HTTP_HOST" => "localhost"}
    extra = AgentCat::RequestContext.extra_from_env(env)

    previous = AgentCat::RequestContext.capture(extra, env)
    begin
      tool_result(server, "echo", {msg: "hi"})
    ensure
      AgentCat::RequestContext.restore(previous)
    end

    assert_equal "ann", seen.headers["x-user"]
    assert seen.headers.frozen?
    assert_equal "sess-1", seen.transport_session_id
    assert_same env, seen.request
  end

  def test_stdio_has_empty_headers_and_no_request
    seen = nil
    server = build_server
    track(server, project_id: PROJECT_ID, event_tags: ->(tool_call) {
      seen = tool_call
      {}
    })

    tool_result(server, "echo", {msg: "hi"})

    assert_equal({}, seen.headers)
    assert_equal({}, seen.meta)
    assert_nil seen.request
    assert_nil seen.transport_session_id
    refute_nil seen.server_context
  end

  def test_client_identity_comes_from_the_initialize_handshake
    seen = nil
    server = build_server
    track(server, project_id: PROJECT_ID, event_tags: ->(tool_call) {
      seen = tool_call
      {}
    })
    session = MCP::ServerSession.new(server: server, transport: nil)
    session.handle({jsonrpc: "2.0", id: 1, method: "initialize", params: {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: "Claude Desktop", version: "1.2.3"}}})

    session.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "echo", arguments: {msg: "hi", session_id: "start"}}})
    AgentCat.flush(timeout: 1)

    assert_equal "Claude Desktop", seen.client_name
    assert_equal "1.2.3", seen.client_version
    # The handshake's version belongs to the session; the call itself claims none (PHP).
    assert_nil seen.protocol_version
  end

  def test_client_identity_and_protocol_version_come_from_sep_2575_meta
    seen = nil
    server = build_server
    track(server, project_id: PROJECT_ID, event_tags: ->(tool_call) {
      seen = tool_call
      {}
    })
    meta = {
      "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
      "io.modelcontextprotocol/clientCapabilities" => {},
      "io.modelcontextprotocol/clientInfo" => {"name" => "Codex", "version" => "2.0"}
    }

    call_tool_with_meta(server, "echo", {msg: "hi", session_id: "start"}, meta)
    AgentCat.flush(timeout: 1)

    assert_equal "Codex", seen.client_name
    assert_equal "2.0", seen.client_version
    assert_equal "2026-07-28", seen.protocol_version
    assert_equal meta, seen.meta
    assert seen.meta.frozen?
  end

  def test_a_two_argument_hook_logs_one_warn_at_track_time
    server = build_server
    log = capture_log { track(server, project_id: PROJECT_ID, identify: ->(arguments, server_context) {}, event_tags: ->(tool_call) {}) }

    lines = log.lines.grep(/takes 2 arguments/)
    assert_equal 1, lines.size
    assert_match(/\AWARN: identify takes 2 arguments, but hooks now get one AgentCat::ToolCall/, lines.first)
  end

  def test_a_two_argument_callable_object_is_warned_about_too
    callable = Class.new { def call(_arguments, _server_context) = {} }.new
    log = capture_log { track(build_server, project_id: PROJECT_ID, event_properties: callable) }

    assert_match(/WARN: event_properties takes 2 arguments/, log)
  end

  # Called with the ToolCall all the same: the old lambda raises ArgumentError, which
  # costs that hook's value, never the tool call.
  def test_an_old_two_argument_hook_does_not_break_the_call
    server = build_server
    client = RecordingClient.new
    capture_log { track(server, project_id: PROJECT_ID, client: client, event_tags: ->(_arguments, _server_context) { {"env" => "prod"} }) }

    result = tool_result(server, "echo", {msg: "hi"})

    assert_equal "hi", texts_of(result).last
    refute client.last_event[:tags].key?("env")
  end

  def test_tool_call_can_be_built_by_hand_for_hook_unit_tests
    tool_call = AgentCat::ToolCall.new(tool_name: "echo", arguments: {msg: "hi"}, headers: {"User-Agent" => "x"})

    assert_equal({"msg" => "hi"}, tool_call.arguments)
    assert_equal({"user-agent" => "x"}, tool_call.headers)
    assert tool_call.frozen?
    assert_raises(FrozenError) { tool_call.arguments["msg"] = "no" }
  end
end
