require_relative "test_helper"

# Multi round-trip requests (SEP-2322): a tool can answer `input_required` instead of a
# result, and the agent retries with `inputResponses`. Same handling as the Go/TS SDKs:
# the intermediate round is tagged and left undecorated, the retry is tagged
# `continuation` and gets the usual mint-back.
class MrtrTest < Minitest::Test
  include AgentCatTestHelpers

  # The gem only allows `input_required` on the 2026-07-28 stateless lifecycle.
  MODERN_META = {
    "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
    "io.modelcontextprotocol/clientCapabilities" => {},
    "io.modelcontextprotocol/clientInfo" => {"name" => "claude-code", "version" => "2.1.0"}
  }.freeze

  def setup
    super
    skip "mcp #{MCP::VERSION} has no input_required results" unless defined?(MCP::Server::InputRequiredResult)
  end

  # Asks for input on the first round; answers once a retry brings the request state back.
  def asking_tool(output_schema: nil)
    MCP::Tool.define(name: "ask", description: "Asks first", output_schema: output_schema,
      input_schema: {type: "object", properties: {q: {type: "string"}}}) do |server_context:, **|
      if server_context.request_state
        MCP::Tool::Response.new([{type: "text", text: "done"}], structured_content: output_schema && {answer: "done"})
      else
        MCP::Server::InputRequiredResult.new(request_state: "round-1")
      end
    end
  end

  def first_round(server)
    response = server.handle({jsonrpc: "2.0", id: 1, method: "tools/call",
      params: {name: "ask", arguments: {q: "x", session_id: "start"}, _meta: MODERN_META}})
    AgentCat.flush(timeout: 1)
    response
  end

  def retry_round(server)
    response = server.handle({jsonrpc: "2.0", id: 2, method: "tools/call",
      params: {name: "ask", arguments: {q: "x", session_id: "start"}, _meta: MODERN_META,
               inputResponses: {"confirm" => {"action" => "accept"}}, requestState: "round-1"}})
    AgentCat.flush(timeout: 1)
    response
  end

  def test_input_required_round_is_tagged_and_recorded_as_a_hash
    server = build_server(tools: [asking_tool])
    client = track(server, project_id: PROJECT_ID)

    first_round(server)

    event = client.last_event
    assert_equal "input_required", event[:tags]["agentcat_mrtr"]
    assert_equal({resultType: "input_required", requestState: "round-1"}, event[:response])
    refute event[:is_error]
  end

  # The completing round carries the session text and the `mcp_session` mirror, not this one.
  def test_input_required_round_is_not_decorated
    server = build_server(tools: [asking_tool(output_schema: {type: "object", properties: {answer: {type: "string"}}})])
    track(server, project_id: PROJECT_ID)

    response = first_round(server)

    assert_equal({resultType: "input_required", requestState: "round-1"}, response[:result])
  end

  def test_continuation_round_is_tagged_and_decorated
    server = build_server(tools: [asking_tool])
    client = track(server, project_id: PROJECT_ID)

    response = retry_round(server)

    assert_equal "continuation", client.last_event[:tags]["agentcat_mrtr"]
    assert_match(/\A\[session_id issued/, response[:result][:content].first[:text])
    assert_equal "done", response[:result][:content].last[:text]
  end

  # A retry that asks for more input again is an intermediate round, not a continuation.
  def test_a_retry_that_asks_again_is_tagged_input_required
    again = MCP::Tool.define(name: "ask", description: "Always asks",
      input_schema: {type: "object", properties: {q: {type: "string"}}}) { |**| MCP::Server::InputRequiredResult.new(request_state: "round-2") }
    server = build_server(tools: [again])
    client = track(server, project_id: PROJECT_ID)

    retry_round(server)

    assert_equal "input_required", client.last_event[:tags]["agentcat_mrtr"]
  end

  def test_an_ordinary_call_has_no_mrtr_tag
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi", session_id: "start"})

    refute client.last_event[:tags].key?("agentcat_mrtr")
  end
end
