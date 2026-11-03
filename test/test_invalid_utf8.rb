require_relative "test_helper"
require "json"
require "minitest/mock"

# Binary or malformed strings make JSON encoding raise, which would lose the whole
# event. Every string is scrubbed to valid UTF-8 (bad bytes become U+FFFD) before the
# event is encoded.
class InvalidUtf8Test < Minitest::Test
  include AgentCatTestHelpers

  # Encodes each event to JSON the way the real client does, so a string JSON can't
  # encode loses the event here too.
  class JsonRecordingClient < RecordingClient
    def post_event(event)
      @events << JSON.parse(JSON.generate(event))
      {"status" => "accepted"}
    end
  end

  BINARY = "bin\xFF".b
  MALFORMED = (+"caf\xC3(").force_encoding(Encoding::UTF_8)

  def track_json(server, **options)
    track(server, project_id: PROJECT_ID, client: JsonRecordingClient.new, **options)
  end

  def test_binary_argument_and_response_are_delivered_scrubbed
    server = build_server
    client = track_json(server)

    tool_result(server, "echo", {msg: BINARY})

    event = client.last_event
    refute_nil event, "the event was lost"
    assert_equal "bin�", event["parameters"]["arguments"]["msg"]
    assert_equal "bin�", event["response"]["content"].last["text"]
  end

  def test_malformed_utf8_argument_and_response_are_delivered_scrubbed
    server = build_server
    client = track_json(server)

    tool_result(server, "echo", {msg: MALFORMED})

    event = client.last_event
    refute_nil event, "the event was lost"
    assert_equal "caf�(", event["parameters"]["arguments"]["msg"]
    assert_equal "caf�(", event["response"]["content"].last["text"]
  end

  # A long malformed string goes through truncation's byte budget, which encodes the
  # event to JSON: unscrubbed, that would raise before anything was cut.
  def test_oversized_malformed_response_is_delivered_truncated
    tool = echo_tool(name: "big") { |**| MCP::Tool::Response.new([{type: "text", text: MALFORMED * 30_000}]) }
    server = build_server(tools: [tool])
    client = track_json(server)

    tool_result(server, "big", {msg: "x"})

    text = client.last_event["response"]["content"].last["text"]
    assert text.valid_encoding?
    assert text.end_with?(AgentCat::PayloadLimits::TRUNCATION_SUFFIX)
  end

  def test_binary_error_message_is_delivered_scrubbed
    tool = echo_tool(name: "boom") { |**| raise ArgumentError, "bad \xFF input".b }
    server = build_server(tools: [tool])
    client = track_json(server)

    call_tool(server, "boom", {msg: "x"})
    AgentCat.flush(timeout: 1)

    event = client.last_event
    refute_nil event, "the event was lost"
    assert_equal "bad � input", event["error"]["message"]
  end

  def test_binary_identify_data_tags_and_properties_are_delivered_scrubbed
    server = build_server
    client = track_json(
      server,
      identify: ->(*) { AgentCat::UserIdentity.new(user_id: "u\xFF".b, user_name: MALFORMED, user_data: {"k\xFF".b => BINARY}) },
      event_tags: ->(*) { {"env" => BINARY} },
      event_properties: ->(*) { {"note" => MALFORMED, "list" => [BINARY]} }
    )

    tool_result(server, "echo", {msg: "hi"})

    event = client.last_event
    refute_nil event, "the event was lost"
    assert_equal "u�", event["identify_actor_given_id"]
    assert_equal "caf�(", event["identify_actor_name"]
    assert_equal({"k�" => "bin�"}, event["identify_data"])
    assert_equal "bin�", event["tags"]["env"]
    assert_equal "caf�(", event["properties"]["note"]
    assert_equal ["bin�"], event["properties"]["list"]
  end

  # The redaction hook gets valid UTF-8, so a regex in it can't raise and drop the event.
  def test_redaction_hook_sees_scrubbed_strings
    server = build_server
    client = track_json(server, redact_sensitive_information: ->(text) { text.gsub("secret", "[x]") })

    tool_result(server, "echo", {msg: "secret #{BINARY}".b})

    event = client.last_event
    refute_nil event, "the event was lost"
    assert_equal "[x] bin�", event["parameters"]["arguments"]["msg"]
  end

  def test_untracked_custom_event_with_binary_strings_is_delivered
    client = JsonRecordingClient.new
    AgentCat::Client.stub(:post_event, ->(event) { client.post_event(event) }) do
      AgentCat.publish_custom_event("ses_123", PROJECT_ID, resource_name: "job", parameters: {"raw" => BINARY})
      AgentCat.flush(timeout: 1)
    end

    refute_nil client.last_event, "the event was lost"
    assert_equal "bin�", client.last_event["parameters"]["raw"]
  end
end
