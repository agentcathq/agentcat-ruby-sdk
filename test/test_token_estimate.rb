require_relative "test_helper"

# The vectors are the shared ones pinned in the Go/TS/Python SDKs
# (agentcat-go-sdk internal/tokens/estimate_test.go), so the four SDKs report the same
# numbers for the same call.
class TokenEstimateTest < Minitest::Test
  include AgentCatTestHelpers

  def text(value)
    {"type" => "text", "text" => value}
  end

  def test_estimate
    {0 => 0, 1 => 1, 7 => 2, 13 => 4, 4096 => 1171, -1 => 0, 7_516_192_765 => 2_147_483_647}.each do |bytes, want|
      assert_equal want, AgentCat::TokenEstimate.estimate(bytes), "estimate(#{bytes})"
    end
  end

  def test_input_tokens
    {
      {"q" => "hello"} => 4,
      {} => 1,
      {"name" => "café"} => 5,
      {"html" => "<a>&</a>"} => 6,
      {"t" => "你好"} => 4,
      {"ids" => [1, 2, 3], "opts" => {"deep" => true, "n" => nil}} => 13
    }.each do |args, want|
      assert_equal want, AgentCat::TokenEstimate.input_tokens(args), "input_tokens(#{args.inspect})"
    end
  end

  def test_input_tokens_absent_or_unencodable
    assert_nil AgentCat::TokenEstimate.input_tokens(nil)
    assert_nil AgentCat::TokenEstimate.input_tokens({"n" => Float::NAN})
  end

  def test_output_tokens
    {
      "one text block" => [{"content" => [text("hello world")]}, 4],
      "summed before ceil" => [{"content" => [text("abcd"), text("e")]}, 2],
      "empty text" => [{"content" => [text("")]}, 0],
      "image only" => [{"content" => [{"type" => "image", "data" => "QUJD", "mimeType" => "image/png"}]}, 0],
      "resource text" => [{"content" => [{"type" => "resource", "resource" => {"uri" => "file:///a", "text" => "resource body"}}]}, 4],
      "resource blob" => [{"content" => [{"type" => "resource", "resource" => {"uri" => "file:///a", "blob" => "QUJD"}}]}, 0],
      "structured ignored" => [{"content" => [text("hi")], "structuredContent" => {"big" => "y" * 1000}}, 1],
      "isError ignored" => [{"content" => [text("hi")], "isError" => true}, 1],
      "4k text" => [{"content" => [text("x" * 4096)]}, 1171],
      "non-string text" => [{"content" => [{"type" => "text", "text" => 42}, nil, "str"]}, 0],
      "no content list falls back" => [{"result" => "ok"}, 5],
      "empty content, structured-only" => [{"content" => [], "structuredContent" => {"result" => "ok"}}, 5],
      "empty content, no structuredContent" => [{"content" => []}, 0],
      "empty content, nil structuredContent" => [{"content" => [], "structuredContent" => nil}, 0],
      "image-only content, structuredContent present" => [{"content" => [{"type" => "image", "data" => "QUJD", "mimeType" => "image/png"}], "structuredContent" => {"result" => "ok"}}, 0]
    }.each do |name, (response, want)|
      assert_equal want, AgentCat::TokenEstimate.output_tokens(response), name
    end
  end

  # `MCP::Tool::Response#to_h` is symbol-keyed.
  def test_output_tokens_reads_symbol_keys
    assert_equal 4, AgentCat::TokenEstimate.output_tokens({content: [{type: "text", text: "hello world"}]})
  end

  def test_output_tokens_absent
    assert_nil AgentCat::TokenEstimate.output_tokens(nil)
  end

  def test_tool_call_event_carries_both_estimates
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hello world", session_id: "start"})

    event = client.last_event
    assert_equal AgentCat::TokenEstimate.input_tokens({"msg" => "hello world", "session_id" => "start"}), event[:input_tokens]
    # Only the tool's own "hello world" - not the session_id text block we put in front.
    assert_equal 4, event[:output_tokens]
  end

  def test_a_raising_tool_has_input_but_no_output_estimate
    boom = echo_tool(name: "boom") { |**| raise "nope" }
    server = build_server(tools: [boom])
    client = track(server, project_id: PROJECT_ID)

    call_tool(server, "boom", {msg: "hi"})
    AgentCat.flush(timeout: 1)

    event = client.last_event
    refute_nil event[:input_tokens]
    assert_nil event[:output_tokens]
  end
end
