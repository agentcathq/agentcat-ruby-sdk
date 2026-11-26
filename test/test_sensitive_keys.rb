require_relative "test_helper"
require "json"
require "minitest/mock"

class SensitiveKeysTest < Minitest::Test
  include AgentCatTestHelpers

  VECTORS = JSON.parse(File.read(File.join(__dir__, "fixtures", "sensitive_keys_vectors.json")))

  def test_key_vectors
    VECTORS["keys"].each do |vector|
      assert_equal vector["sensitive"], AgentCat::SensitiveKeys.is_sensitive_key(vector["key"]), vector["key"]
    end
  end

  # Hash equality in Ruby ignores key order. The arrays let a nil case use assert_equal.
  def test_tree_vectors
    VECTORS["trees"].each do |vector|
      input = vector["input"]
      before = Marshal.load(Marshal.dump(input))

      assert_equal [vector["expected"]], [AgentCat::SensitiveKeys.mask_sensitive_keys(input)], vector["name"]
      assert_equal [before], [input], vector["name"]
    end
  end

  # Ruby only: Symbol keys are tested by name and kept as Symbols, and a cycle is masked.
  def test_symbol_keys_and_cycles
    cycle = {"name" => "loop"}
    cycle["self"] = cycle

    masked = AgentCat::SensitiveKeys.mask_sensitive_keys({authorization: "Bearer x", properties: {apiKey: {type: "string"}}, loop: cycle})

    assert_equal({authorization: "[redacted]", properties: {apiKey: {type: "string"}}, loop: {"name" => "loop", "self" => "[redacted]"}}, masked)
  end

  def test_the_sender_gets_masked_headers_and_the_request_keeps_its_own
    server = MCP::Server.new(name: "auth-server", version: "1.0.0", tools: [echo_tool],
      server_context: {auth_info: {"token" => "abc.def", "clientId" => "client-1"}})
    client = track(server, project_id: PROJECT_ID)
    captured = AgentCat::RequestContext.extra_from_env({
      "HTTP_HOST" => "localhost", "HTTP_AUTHORIZATION" => "Bearer abc.def", "HTTP_COOKIE" => "sid=1",
      "HTTP_X_API_KEY" => "k-123", "HTTP_USER_AGENT" => "claude-code/2.1.0",
      "HTTP_X_ANTHROPIC_CLIENT" => "claude-code", "HTTP_MCP_SESSION_ID" => "0b1c"
    })

    previous = AgentCat::RequestContext.capture(captured)
    begin
      tool_result(server, "echo", {msg: "hi", session_id: "start"})
    ensure
      AgentCat::RequestContext.restore(previous)
    end

    extra = client.last_event[:parameters]["extra"]
    assert_equal({"authorization" => "[redacted]", "cookie" => "[redacted]", "x-api-key" => "[redacted]",
                  "user-agent" => "claude-code/2.1.0", "x-anthropic-client" => "claude-code",
                  "mcp-session-id" => "0b1c", "host" => "localhost"}, extra.dig("requestInfo", "headers"))
    assert_equal "[redacted]", extra["authInfo"]
    assert_equal "Bearer abc.def", captured.dig("requestInfo", "headers", "authorization")
    assert_equal "sid=1", captured.dig("requestInfo", "headers", "cookie")
  end

  def test_a_field_the_mask_fails_on_is_dropped
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    log = capture_log(level: Logger::WARN) do
      AgentCat::SensitiveKeys.stub(:mask_sensitive_keys, ->(_value) { raise "boom" }) do
        tool_result(server, "echo", {msg: "hi", session_id: "start"})
      end
    end

    assert_equal({}, client.last_event[:parameters])
    refute client.last_event.key?(:response)
    assert_includes log, "masking sensitive keys in parameters of the event of tool echo failed with RuntimeError; the event goes out without parameters"
  end
end
