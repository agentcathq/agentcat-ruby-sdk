require_relative "test_helper"
require "minitest/mock"

# As in TS, a `tools/call` the `mcp` gem turns away before the tool runs - no
# tool by that name, or arguments that fail its required/schema check - is recorded as
# one error event. The gem's JSON-RPC answer reaches the client as the gem made it; an
# isError result gets the session block like any tool result (TS v1).
class RejectedCallsTest < Minitest::Test
  include AgentCatTestHelpers

  def rpc(server, name, arguments, id: 2)
    server.handle({jsonrpc: "2.0", id: id, method: "tools/call", params: {name: name, arguments: arguments}})
  end

  def test_unknown_tool_records_one_error_event_and_keeps_the_json_rpc_error
    untracked = rpc(build_server, "nope", {q: 1})
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    response = rpc(server, "nope", {q: 1})
    AgentCat.flush(timeout: 1)

    assert_equal untracked, response
    assert_match(/Tool not found: nope/, response.dig(:error, :data).to_s + response.dig(:error, :message).to_s)
    assert_equal 1, client.events.size
    event = client.last_event
    assert_equal "mcp:tools/call", event[:event_type]
    assert_equal "nope", event[:resource_name]
    assert event[:is_error]
    assert_equal "Tool not found: nope", event[:error]["message"]
    assert_equal "MCP::Server::RequestHandlerError", event[:error]["type"]
    assert_nil event[:response]
    assert_equal({"q" => 1}, event[:parameters]["arguments"])
    assert_equal 2, event[:parameters]["extra"]["requestId"]
    assert_equal "minted", event[:tags]["agentcat_session_id_source"]
    assert_match(/\Ases_/, event[:session_id])
  end

  def test_unknown_tool_keeps_a_supplied_session
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    session_id = agentcat_meta(tool_result(server, "echo", {msg: "hi"}))[:session_id]

    rpc(server, "nope", {session_id: session_id})
    AgentCat.flush(timeout: 1)

    assert_equal session_id, client.last_event[:session_id]
    assert_equal "supplied", client.last_event[:tags]["agentcat_session_id_source"]
  end

  def test_missing_required_argument_records_one_error_event_and_mints_back
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    result = rpc(server, "echo", {context: "say hi"})[:result]
    AgentCat.flush(timeout: 1)

    assert result[:isError]
    texts = texts_of(result)
    assert_equal 2, texts.size
    assert_match(/\A\[session_id issued/, texts.first)
    assert_equal "Missing required arguments: msg", texts.last
    assert_equal 1, client.events.size
    event = client.last_event
    assert_equal "echo", event[:resource_name]
    assert event[:is_error]
    assert_equal({"message" => "Missing required arguments: msg", "platform" => "ruby"}, event[:error])
    # The event records the gem's own result; the session block is for the agent only.
    assert_equal ["Missing required arguments: msg"], event[:response][:content].map { |block| block[:text] }
    assert_equal "say hi", event[:user_intent]
    assert_equal agentcat_meta(result)[:session_id], event[:session_id]
  end

  # With a session the agent already has, there is nothing to tell it: the gem's answer
  # goes out exactly as an untracked server would send it.
  def test_missing_required_argument_with_a_supplied_session_leaves_the_response_unchanged
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    session_id = agentcat_meta(tool_result(server, "echo", {msg: "hi"}))[:session_id]

    response = rpc(server, "echo", {session_id: session_id})
    AgentCat.flush(timeout: 1)

    assert_equal({content: [{type: "text", text: "Missing required arguments: msg"}], isError: true}, response[:result])
    assert_equal 2, client.events.size
    assert_equal session_id, client.last_event[:session_id]
    assert client.last_event[:is_error]
  end

  def test_schema_validation_error_records_one_error_event
    configuration = MCP::Configuration.new(validate_tool_call_arguments: true)
    server = MCP::Server.new(name: "test", tools: [echo_tool], configuration: configuration)
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: 5})

    assert result[:isError]
    assert_match(/Invalid arguments/, texts_of(result).last)
    assert_equal 1, client.events.size
    assert client.last_event[:is_error]
    assert_match(/\AInvalid arguments/, client.last_event[:error]["message"])
  end

  def test_a_call_the_tool_answers_is_recorded_once
    failing = echo_tool(name: "boom") { |msg:| raise "kaput #{msg}" }
    server = build_server(tools: [echo_tool, failing])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi"})
    call_tool(server, "boom", {msg: "x"})
    AgentCat.flush(timeout: 1)

    assert_equal 2, client.events.size
    assert_equal "RuntimeError", client.last_event[:error]["type"]
  end

  def test_a_tool_that_returns_its_own_error_result_is_recorded_once
    tool = echo_tool(name: "soft") { |msg:| MCP::Tool::Response.new([{type: "text", text: "no #{msg}"}], error: true) }
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "soft", {msg: "x"})

    assert_equal 1, client.events.size
  end

  def test_the_json_string_path_records_rejected_calls_too
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    json = server.handle_json(JSON.generate({jsonrpc: "2.0", id: 9, method: "tools/call", params: {name: "nope", arguments: {}}}))
    AgentCat.flush(timeout: 1)

    assert JSON.parse(json).key?("error")
    assert_equal "nope", client.last_event[:resource_name]
    assert_equal 9, client.last_event[:parameters]["extra"]["requestId"]
  end

  def test_tracing_off_records_nothing
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_tracing: false)

    rpc(server, "nope", {})
    rpc(server, "echo", {})
    AgentCat.flush(timeout: 1)

    assert_empty client.events
  end

  def test_an_untracked_server_is_left_alone
    server = build_server
    track(server, project_id: PROJECT_ID)
    AgentCat.reset!

    assert rpc(server, "nope", {}).key?(:error)
  end

  def test_hooks_see_the_rejected_call
    seen = []
    server = build_server
    client = track(server, project_id: PROJECT_ID, event_tags: ->(tool_call) {
      seen << tool_call.tool_name
      {"kind" => "rejected"}
    })

    rpc(server, "nope", {})
    AgentCat.flush(timeout: 1)

    assert_equal ["nope"], seen
    assert_equal "rejected", client.last_event[:tags]["kind"]
  end

  # Without the gem's private `call_tool`, the feature is off with one ERROR line,
  # and rejected calls go back to producing no event.
  def test_a_missing_call_tool_turns_the_feature_off
    probe = AgentCat::PrivateMembers.method(:probe)
    missing = AgentCat::PrivateMembers::SERVER_CALL_TOOL
    server = client = nil
    log = AgentCat::PrivateMembers.stub(:probe, ->(member) { member.equal?(missing) ? false : probe.call(member) }) do
      capture_log do
        server = build_server
        client = track(server, project_id: PROJECT_ID)
      end
    end

    assert_equal 1, log.lines.grep(/ERROR: .*MCP::Server#call_tool/).size, log
    assert rpc(server, "nope", {}).key?(:error)
    AgentCat.flush(timeout: 1)
    assert_empty client.events
  end
end
