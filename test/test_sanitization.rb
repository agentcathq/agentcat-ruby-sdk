require_relative "test_helper"
require "minitest/mock"
require "json"

class SanitizationTest < Minitest::Test
  def build_event(parameters: {}, options: {}, **extra)
    props = {
      id: "evt_123456789012345678901234567z",
      session_id: "ses_123456789012345678901234567z",
      event_type: "mcp:tools/call",
      resource_name: "echo",
      parameters: parameters,
      duration: 10,
      timestamp: Time.now.utc.iso8601,
      agentcat_version: AgentCat::VERSION
    }.merge(extra).merge(options)
    AgentCat::UnredactedEvent.new(**props)
  end

  def test_leaves_plain_strings_alone
    event = build_event(parameters: {"msg" => "hello"})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal "hello", event.parameters["msg"]
  end

  def test_leaves_small_base64_shaped_strings_alone
    event = build_event(parameters: {"token" => "QWxhZGRpbiBpemFnbyBjb20="})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal "QWxhZGRpbiBpemFnbyBjb20=", event.parameters["token"]
  end

  def test_redacts_large_base64_strings
    event = build_event(parameters: {"blob" => "A" * 12_000})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, event.parameters["blob"]
  end

  def test_non_base64_large_strings_pass_through
    value = "-" * 12_000
    event = build_event(parameters: {"text" => value})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal value, event.parameters["text"]
  end

  def test_scans_nested_parameters
    event = build_event(parameters: {"nested" => {"deeper" => {"blob" => "A" * 12_000}}})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, event.parameters.dig("nested", "deeper", "blob")
  end

  def test_redacts_image_content_blocks
    event = build_event(response: {content: [{type: "image", data: "abc", mimeType: "image/png"}]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal({type: "text", text: AgentCat::Sanitization::IMAGE_REDACTED}, event.response[:content].first)
  end

  def test_redacts_audio_content_blocks
    event = build_event(response: {content: [{type: "audio", data: "abc", mimeType: "audio/wav"}]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal({type: "text", text: AgentCat::Sanitization::AUDIO_REDACTED}, event.response[:content].first)
  end

  # `blob` lives under `resource:`, per the real `EmbeddedResourceContent` shape — not
  # flat on the block itself. A flat `{type: "resource", blob: ...}` is not a shape any
  # conforming MCP server actually sends.
  def test_redacts_binary_resource_blobs
    event = build_event(response: {content: [
      {type: "resource", resource: {uri: "file:///x", blob: "abc", mimeType: "application/octet-stream"}}
    ]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal({type: "text", text: AgentCat::Sanitization::BINARY_RESOURCE_REDACTED}, event.response[:content].first)
  end

  def test_keeps_text_resource_blocks_unredacted
    event = build_event(response: {content: [
      {type: "resource", resource: {uri: "file:///readme.md", text: "# Hello", mimeType: "text/markdown"}}
    ]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal(
      {type: "resource", resource: {uri: "file:///readme.md", text: "# Hello", mimeType: "text/markdown"}},
      event.response[:content].first
    )
  end

  def test_redacts_binary_resource_blobs_with_string_keyed_resource
    event = build_event(response: {content: [
      {"type" => "resource", "resource" => {"uri" => "file:///x", "blob" => "abc"}}
    ]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal({type: "text", text: AgentCat::Sanitization::BINARY_RESOURCE_REDACTED}, event.response[:content].first)
  end

  def test_keeps_text_and_resource_link_blocks
    response = {content: [
      {type: "text", text: "hello"},
      {type: "resource_link", uri: "file:///readme", title: "README"}
    ]}
    event = build_event(response: response)

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal response[:content], event.response[:content]
  end

  # `response` is `T.untyped` — every other content-block test wraps blocks in
  # `{content: [...]}`, but a response can also be a bare array of blocks directly.
  def test_sanitizes_a_bare_array_response_block_by_block
    event = build_event(response: [
      {type: "image", data: "abc", mimeType: "image/png"},
      {type: "text", text: "hi"}
    ])

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal({type: "text", text: AgentCat::Sanitization::IMAGE_REDACTED}, event.response.first)
    assert_equal({type: "text", text: "hi"}, event.response.last)
  end

  # Neither Hash nor Array — passes through untouched.
  def test_leaves_a_non_container_response_alone
    event = build_event(response: "plain text response")

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal "plain text response", event.response
  end

  def test_redacts_unknown_content_types
    event = build_event(response: {content: [{type: "video", data: "abc"}]})

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal "[unsupported content type \"video\" redacted - not supported by AgentCat]", event.response[:content].first[:text]
  end

  def test_handles_circular_structures_without_looping
    circular = {}
    circular["self"] = circular
    event = build_event(parameters: circular)

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal AgentCat::PayloadLimits::CIRCULAR_MARKER, event.parameters["self"]
  end

  def test_bounds_deeply_nested_structures
    nested = {}
    ref = nested
    150.times do
      ref["next"] = {}
      ref = ref["next"]
    end
    event = build_event(parameters: nested)

    AgentCat::Sanitization.sanitize_event(event)

    value = event.parameters
    150.times do
      child = value["next"]
      assert_equal AgentCat::PayloadLimits::MAX_DEPTH_EXCEEDED_MARKER, child unless child.is_a?(Hash)
      break unless child.is_a?(Hash)

      value = child
    end
  end

  def test_sanitizes_identify_data_and_error_and_properties
    event = build_event(
      parameters: {},
      identify_data: {"blob" => "A" * 12_000},
      error: {"type" => "RuntimeError", "message" => "B" * 12_000},
      properties: {"payload" => "C" * 12_000}
    )

    AgentCat::Sanitization.sanitize_event(event)

    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, event.identify_data["blob"]
    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, event.error["message"]
    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, event.properties["payload"]
  end

  def test_scrub_event_makes_every_string_valid_utf8_without_touching_the_callers_objects
    args = {"bad\xFF".b => ["x\xFF".b]}
    event = build_event(
      parameters: args,
      options: {user_intent: "why\xFF".b, error: {"message" => "m\xC3"}, tags: {"t" => "v\xFF".b}}
    )

    AgentCat::Sanitization.scrub_event(event)

    assert_equal({"bad\uFFFD" => ["x\uFFFD"]}, event.parameters)
    assert_equal "why\uFFFD", event.user_intent
    assert_equal "m\uFFFD", event.error["message"]
    assert_equal "v\uFFFD", event.tags["t"]
    assert_equal ["x\xFF".b], args["bad\xFF".b]
    JSON.generate(event.to_wire_hash)
  end

  def test_scrub_event_terminates_on_circular_structures
    cyclic = {"a" => "\xFF".b}
    cyclic["self"] = cyclic
    event = build_event(parameters: {"c" => cyclic})

    AgentCat::Sanitization.scrub_event(event)

    assert_equal "\uFFFD", event.parameters["c"]["a"]
  end

  def test_text_scrub_converts_other_encodings_and_keeps_valid_utf8
    valid = "café"
    assert_same valid, AgentCat::Text.scrub(valid)
    assert_equal "café", AgentCat::Text.scrub((+"caf\xE9").force_encoding(Encoding::ISO_8859_1))
    assert_equal "é", AgentCat::Text.scrub("é".b)
  end
end

# Sanitization and truncation run on every event, so a bug in either can't be allowed to
# cost the event - the interceptor and publish_custom_event both deliver it as-is instead.
class SanitizationFailOpenTest < Minitest::Test
  include AgentCatTestHelpers

  def test_tool_call_event_is_delivered_when_sanitization_raises
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    result = AgentCat::Sanitization.stub(:sanitize_event, ->(_event) { raise "sanitizer bug" }) do
      tool_result(server, "echo", {msg: "hello"})
    end

    assert_equal "hello", texts_of(result).last
    assert_equal 1, client.events.size
    assert_equal "hello", client.last_event[:parameters]["arguments"]["msg"]
  end

  def test_tool_call_event_is_delivered_when_truncation_raises
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat::Truncation.stub(:truncate_event, ->(_event) { raise "truncation bug" }) do
      tool_result(server, "echo", {msg: "hello"})
    end

    assert_equal 1, client.events.size
    assert_equal "echo", client.last_event[:resource_name]
  end

  def test_custom_event_is_delivered_when_sanitization_raises
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat::Sanitization.stub(:sanitize_event, ->(_event) { raise "sanitizer bug" }) do
      AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", resource_name: "checkout")
      AgentCat.flush(timeout: 1)
    end

    assert_equal 1, client.events.size
    assert_equal "checkout", client.last_event[:resource_name]
  end
end
