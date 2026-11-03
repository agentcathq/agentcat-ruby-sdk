require_relative "test_helper"
require "json"

class TruncationTest < Minitest::Test
  P = AgentCat::PayloadLimits

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

  # TS `truncateString`: keep `max` UTF-16 code units, then add the suffix on top.
  def test_truncate_string_keeps_the_limit_and_adds_the_suffix
    assert_equal "abcdef...", AgentCat::Truncation.truncate_string("abcdefgh", 6)
  end

  def test_truncate_string_leaves_small_strings_alone
    assert_equal "hello", AgentCat::Truncation.truncate_string("hello", P::MAX_STRING_LENGTH)
    assert_equal "abcdef", AgentCat::Truncation.truncate_string("abcdef", 6)
  end

  # A byte cap would cut "é" (2 bytes) in half and make JSON.generate raise.
  def test_truncate_string_counts_utf16_code_units_not_bytes
    assert_equal "ééé", AgentCat::Truncation.truncate_string("ééé", 3)
    assert_equal "éé...", AgentCat::Truncation.truncate_string("éééé", 2)
    assert_equal "日本...", AgentCat::Truncation.truncate_string("日本語", 2)
  end

  # A code point above U+FFFF is two UTF-16 code units, like JS `"😀".length == 2`.
  def test_truncate_string_counts_astral_characters_as_two_units
    assert_equal "😀😀", AgentCat::Truncation.truncate_string("😀😀", 4)
    assert_equal "😀...", AgentCat::Truncation.truncate_string("😀😀", 2)
  end

  # Like the PHP SDK: a surrogate pair that the cut would split is dropped whole.
  def test_truncate_string_drops_a_character_split_at_the_cut
    assert_equal "a...", AgentCat::Truncation.truncate_string("a😀b", 2)
    assert_equal "a😀...", AgentCat::Truncation.truncate_string("a😀b", 3)
  end

  def test_multibyte_strings_cut_at_the_limit_still_encode_as_json
    event = build_event(
      parameters: {"text" => "é" * 40_000},
      options: {user_intent: "😀" * 3_000, server_name: "日" * 500}
    )

    AgentCat::Truncation.truncate_event(event)

    assert event.parameters["text"].valid_encoding?
    assert_equal P::MAX_STRING_LENGTH + 3, event.parameters["text"].length
    assert_equal (P::MAX_USER_INTENT_LENGTH / 2) + 3, event.user_intent.length
    assert_equal P::MAX_METADATA_LENGTH + 3, event.server_name.length
    JSON.generate(event.to_wire_hash)
  end

  def test_caps_user_intent
    event = build_event(parameters: {}, options: {user_intent: "x" * 3_000})

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_USER_INTENT_LENGTH + 3, event.user_intent.bytesize
    assert event.user_intent.end_with?(P::TRUNCATION_SUFFIX)
  end

  def test_caps_resource_name_and_metadata
    event = build_event(
      parameters: {},
      options: {resource_name: "r" * 500, server_name: "s" * 500, server_version: "v" * 500}
    )

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_RESOURCE_NAME_LENGTH + 3, event.resource_name.bytesize
    assert_equal P::MAX_METADATA_LENGTH + 3, event.server_name.bytesize
    assert_equal P::MAX_METADATA_LENGTH + 3, event.server_version.bytesize
  end

  # The connecting client controls these strings, so cap them like the Go/TS SDKs do.
  def test_caps_client_name_and_version
    event = build_event(
      parameters: {},
      options: {client_name: "c" * 500, client_version: "v" * 500}
    )

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_METADATA_LENGTH + 3, event.client_name.bytesize
    assert_equal P::MAX_METADATA_LENGTH + 3, event.client_version.bytesize
  end

  def test_caps_parameter_strings_to_the_32kb_budget
    event = build_event(parameters: {"text" => "-" * 40_000})

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_STRING_LENGTH + 3, event.parameters["text"].bytesize
    assert event.parameters["text"].end_with?(P::TRUNCATION_SUFFIX)
  end

  def test_caps_response_text_blocks
    event = build_event(response: {content: [{type: "text", text: "-" * 40_000}]})

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_CONTENT_TEXT_LENGTH + 3, event.response[:content].first[:text].bytesize
  end

  def test_caps_error_message_and_truncates_stack_frames_from_both_ends
    error = {"type" => "RuntimeError", "message" => "x" * 3_000, "frames" => (1..80).to_a}
    event = build_event(parameters: {}, options: {error: error})

    AgentCat::Truncation.truncate_event(event)

    assert_equal P::MAX_ERROR_MESSAGE_LENGTH + 3, error["message"].bytesize
    assert error["message"].end_with?(P::TRUNCATION_SUFFIX)
    assert_equal 50, error["frames"].size
    assert_equal 1, error["frames"].first
    assert_equal 80, error["frames"].last
  end

  def test_limits_hash_breadth_with_a_marker
    event = build_event(parameters: Array.new(150) { |i| ["k#{i}", "v"] }.to_h)

    AgentCat::Truncation.truncate_event(event)

    assert_equal 101, event.parameters.size
    assert_equal "[MaxProperties ~]", event.parameters[P::TRUNCATION_SUFFIX]
  end

  def test_limits_array_breadth_with_a_marker
    event = build_event(parameters: {"items" => Array.new(150) { |i| "item#{i}" }})

    AgentCat::Truncation.truncate_event(event)

    assert_equal 101, event.parameters["items"].size
    assert_equal "[MaxProperties ~]", event.parameters["items"].last
  end

  def test_replaces_overdeep_structure_with_markers
    nested = {}
    ref = nested
    15.times do
      ref["l"] = {}
      ref = ref["l"]
    end
    event = build_event(parameters: nested)

    AgentCat::Truncation.truncate_event(event)

    value = event.parameters
    10.times { value = value["l"] }
    assert_equal "[Object]", value
  end

  def test_marks_circular_structures
    circular = {}
    circular["self"] = circular
    event = build_event(parameters: circular)

    AgentCat::Truncation.truncate_event(event)

    assert_equal "[Circular ~]", event.parameters["self"]
  end

  # Same strings as TS `normalize`.
  def test_normalizes_non_finite_floats
    event = build_event(parameters: {"nan" => Float::NAN, "inf" => Float::INFINITY, "neg" => -Float::INFINITY})

    AgentCat::Truncation.truncate_event(event)

    assert_equal "[NaN]", event.parameters["nan"]
    assert_equal "[Infinity]", event.parameters["inf"]
    assert_equal "[-Infinity]", event.parameters["neg"]
  end

  # A string-keyed block gets its text cut under "text", not a second :text key.
  def test_caps_string_keyed_response_text_blocks_without_a_duplicate_key
    event = build_event(response: {"content" => [{"type" => "text", "text" => "-" * 40_000}]})

    AgentCat::Truncation.truncate_event(event)

    block = event.response["content"].first
    assert_equal ["type", "text"], block.keys
    assert_equal P::MAX_CONTENT_TEXT_LENGTH + 3, block["text"].length
  end

  def test_respects_the_event_byte_budget
    parameters = Array.new(20) { |i| ["s#{i}", "-" * 100_000] }.to_h
    event = build_event(parameters: parameters)

    AgentCat::Truncation.truncate_event(event)

    assert_operator JSON.generate(event.to_wire_hash).bytesize, :<=, P::MAX_EVENT_BYTES
  end

  def test_large_events_keep_their_key_surface_after_cutting_strings
    parameters = Array.new(5) { |i| ["s#{i}", "-" * 200_000] }.to_h
    event = build_event(parameters: parameters)

    AgentCat::Truncation.truncate_event(event)

    assert_equal 5, event.parameters.size
    assert event.parameters.values.all? { |value| value.is_a?(String) }
    assert_operator JSON.generate(event.to_wire_hash).bytesize, :<=, P::MAX_EVENT_BYTES
  end

  # Neither Hash, Array, String, Float, nil/true/false, nor Numeric — the only way to reach
  # `normalize_non_primitive` at all (every other test's parameters stay inside those types).
  def test_normalizes_symbols_times_and_arbitrary_objects
    unjsonable = Class.new do
      def to_json(*)
        raise TypeError, "won't serialize"
      end

      def to_s
        "stringified-fallback"
      end
    end.new
    time = Time.utc(2026, 1, 2, 3, 4, 5)
    event = build_event(parameters: {"sym" => :hello, "time" => time, "weird" => unjsonable})

    AgentCat::Truncation.truncate_event(event)

    assert_equal "hello", event.parameters["sym"]
    assert_equal time.iso8601, event.parameters["time"]
    assert_equal "stringified-fallback", event.parameters["weird"]
  end

  # `response` is `T.untyped` and the only USER_FIELDS member loosely typed enough to hold
  # a bare String instead of a Hash/Array container — the only shape that reaches the
  # last-resort trim's path-length-1 branch (the field itself gets replaced directly,
  # rather than something nested inside it). Kept as the single largest trim candidate —
  # the parameter strings stay under MAX_STRING_LENGTH so they're never clamped by the
  # earlier normalize pass — so it's unambiguously the one that gets cut further.
  def test_last_resort_trim_replaces_a_bare_top_level_field_directly
    event = build_event(
      parameters: Array.new(3) { |i| ["p#{i}", "-" * 25_000] }.to_h,
      response: "-" * 200_000
    )

    AgentCat::Truncation.truncate_event(event)

    assert_kind_of String, event.response
    assert_operator event.response.length, :<, P::MAX_STRING_LENGTH
    assert event.response.end_with?(P::TRUNCATION_SUFFIX)
    assert_operator JSON.generate(event.to_wire_hash).bytesize, :<=, P::MAX_EVENT_BYTES
  end

  # An array is never collapsed to a depth marker while it's a *field's own* value —
  # depth is only spent by nesting a container one level deeper, and `response` (unlike
  # `parameters`) can be an Array directly. That's the only shape that reaches
  # `largest_strings`'/`replace_at`'s Array-index branches, instead of the Hash-key
  # branches every other truncation test exercises.
  def test_last_resort_trim_walks_into_arrays_for_the_largest_strings
    event = build_event(parameters: {}, response: Array.new(5) { "-" * 200_000 })

    AgentCat::Truncation.truncate_event(event)

    assert_equal 5, event.response.size
    assert event.response.all? { |item| item.is_a?(String) && item.length <= P::MAX_STRING_LENGTH + 3 }
    assert_operator JSON.generate(event.to_wire_hash).bytesize, :<=, P::MAX_EVENT_BYTES
  end

  # Tag limits count UTF-16 code units too: 150 emoji are 300 units, over the 200 cap.
  def test_tag_value_limit_counts_utf16_code_units
    tags = AgentCat::Tags.sanitize("ok" => "😀" * 100, "long" => "😀" * 101, "bmp" => "é" * 200)

    assert_equal ["ok", "bmp"], tags.keys
  end

  def test_agent_id_tag_is_clamped_to_200_utf16_code_units_without_splitting
    event = build_event(agent_id: "a" + "😀" * 150)

    tag = event.to_wire_hash[:tags]["agentcat_agent_id"]

    assert_equal "a" + "😀" * 99, tag
    assert tag.valid_encoding?
  end

  # Depth reduction keeps at least 5 levels for `error`, so `frames` and
  # `chained_errors[].frames` stay hashes the backend can parse, not "[Array]"/"[Object]".
  def test_depth_reduction_keeps_error_frames_parseable
    frame = {"function" => "call", "filename" => "app.rb", "lineno" => 3, "in_app" => true}
    error = {
      "type" => "RuntimeError", "message" => "boom", "frames" => [frame.dup],
      "chained_errors" => [{"type" => "ArgumentError", "message" => "cause", "frames" => [frame.dup]}]
    }
    # Fits only once `parameters` is cut down to depth 1.
    parameters = {"a" => "-" * 30_000, "b" => "-" * 30_000, "c" => "-" * 30_000, "deep" => {"d" => "-" * 30_000}}
    event = build_event(parameters: parameters, options: {error: error})

    AgentCat::Truncation.truncate_event(event)

    assert_equal frame, event.error["frames"].first
    assert_equal frame, event.error["chained_errors"].first["frames"].first
    assert_operator JSON.generate(event.to_wire_hash).bytesize, :<=, P::MAX_EVENT_BYTES
  end
end
