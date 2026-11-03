require_relative "test_helper"

class CustomEventTest < Minitest::Test
  include AgentCatTestHelpers

  # The untracked (session-id-string) path has no tracker/Options to pull a client
  # from - it always posts through `AgentCat::Client` itself, same as the real
  # process-wide queue does. Stub that one method directly rather than hit the network.
  # `Client.post_event` runs on the event queue's own worker thread, not this test's -
  # a plain Array capture needs a Mutex, and `Thread.current` (which is per-thread)
  # would silently miss everything.
  def setup
    super
    @posted = []
    @posted_mutex = Mutex.new
    @original_post_event = AgentCat::Client.method(:post_event)
    posted = @posted
    mutex = @posted_mutex
    AgentCat::Client.define_singleton_method(:post_event) do |event|
      mutex.synchronize { posted << event }
      {"status" => "accepted"}
    end
  end

  def teardown
    super
    AgentCat::Client.define_singleton_method(:post_event, &@original_post_event)
  end

  def posted
    @posted_mutex.synchronize { @posted.dup }
  end

  def test_string_form_uses_the_session_id_verbatim
    AgentCat.publish_custom_event("ses_not_a_real_ksuid_at_all", PROJECT_ID, resource_name: "checkout")
    AgentCat.flush(timeout: 1)

    assert_equal 1, posted.size
    assert_equal "ses_not_a_real_ksuid_at_all", posted.first[:session_id]
    assert_equal "agentcat:custom", posted.first[:event_type]
  end

  def test_session_id_kwarg_beats_the_string_argument
    AgentCat.publish_custom_event("ses_from_the_first_arg", PROJECT_ID, session_id: "ses_from_the_kwarg")
    AgentCat.flush(timeout: 1)

    assert_equal "ses_from_the_kwarg", posted.first[:session_id]
  end

  def test_string_form_requires_a_project_id
    AgentCat.publish_custom_event("ses_x", nil)
    AgentCat.flush(timeout: 1)

    assert_empty posted
  end

  def test_string_form_never_raises_on_a_blank_project_id
    assert_silent_about_raising { AgentCat.publish_custom_event("ses_x", "") }
  end

  def test_tracked_server_uses_the_trackers_own_project_id_not_the_argument
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, "proj_this_argument_is_ignored_here", session_id: "ses_t")
    AgentCat.flush(timeout: 1)

    assert_equal PROJECT_ID, client.last_event[:project_id]
  end

  # TS sends `sessionId || null`: the key is always there, null when there's no session.
  def test_tracked_server_without_a_session_id_publishes_untethered
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID)
    AgentCat.flush(timeout: 1)

    assert client.last_event.key?(:session_id)
    assert_nil client.last_event[:session_id]
  end

  def test_an_empty_session_id_string_is_sent_as_null
    AgentCat.publish_custom_event("", PROJECT_ID, resource_name: "checkout")
    AgentCat.flush(timeout: 1)

    assert_equal 1, posted.size
    assert posted.first.key?(:session_id)
    assert_nil posted.first[:session_id]
  end

  def test_an_empty_session_id_kwarg_falls_back_to_the_string_argument
    AgentCat.publish_custom_event("ses_from_the_first_arg", PROJECT_ID, session_id: "")
    AgentCat.flush(timeout: 1)

    assert_equal "ses_from_the_first_arg", posted.first[:session_id]
  end

  # The health signals describe a tool call. A custom event is not one, so it does
  # not get them (TS sends only the customer's own properties).
  def test_custom_events_carry_no_agentcat_health_properties
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", properties: {"plan" => "pro"})
    AgentCat.publish_custom_event("ses_bare", PROJECT_ID, properties: {"plan" => "pro"})
    AgentCat.publish_custom_event("ses_bare", PROJECT_ID)
    AgentCat.flush(timeout: 1)

    assert_equal({"plan" => "pro"}, client.last_event[:properties])
    assert_equal({"plan" => "pro"}, posted.first[:properties])
    refute posted.last.key?(:properties), "no properties at all means no key, like TS"
  end

  # TS's queue exports every event, untracked custom events included, to the
  # process-wide exporters (the first `track` that had any).
  def test_untracked_custom_events_reach_the_process_exporters
    exported = []
    exporter = ->(event) { exported << event }
    track(build_server, project_id: PROJECT_ID, exporters: [exporter])
    track(build_server, project_id: PROJECT_ID, exporters: [->(_event) { flunk "first track wins" }])

    AgentCat.publish_custom_event("ses_bare", PROJECT_ID, resource_name: "feature-usage")
    AgentCat.flush(timeout: 1)

    assert_equal 1, posted.size
    assert_equal ["feature-usage"], exported.map(&:resource_name)
    assert_equal "ses_bare", exported.first.session_id
  end

  def test_reset_forgets_the_process_exporters
    exported = []
    track(build_server, project_id: PROJECT_ID, exporters: [->(event) { exported << event }])
    AgentCat.reset!

    AgentCat.publish_custom_event("ses_bare", PROJECT_ID)
    AgentCat.flush(timeout: 1)

    assert_empty exported
  end

  def test_an_untracked_server_is_dropped_without_raising
    server = build_server # never passed to track()

    assert_silent_about_raising { AgentCat.publish_custom_event(server, PROJECT_ID) }
  end

  def test_a_bad_first_argument_never_raises
    [nil, 42, {not: "a server"}, ["nope"]].each do |bad|
      assert_silent_about_raising { AgentCat.publish_custom_event(bad, PROJECT_ID) }
    end
    assert_empty posted
  end

  def test_event_type_is_always_agentcat_custom
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t")
    AgentCat.flush(timeout: 1)

    assert_equal "agentcat:custom", client.last_event[:event_type]
  end

  def test_custom_event_data_reaches_the_event
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(
      server, PROJECT_ID,
      session_id: "ses_t", resource_name: "checkout", message: "order confirmed",
      parameters: {"order_id" => 42}, duration: 150, is_error: true
    )
    AgentCat.flush(timeout: 1)

    event = client.last_event
    assert_equal "checkout", event[:resource_name]
    assert_equal "order confirmed", event[:user_intent]
    assert_equal({"order_id" => 42}, event[:parameters])
    assert_equal 150, event[:duration]
    assert_equal true, event[:is_error]
  end

  def test_a_mistyped_scalar_field_costs_only_that_field
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", resource_name: 12345, duration: "not-a-number")
    AgentCat.flush(timeout: 1)

    event = client.last_event
    assert_equal "", event[:resource_name]
    assert_equal 0, event[:duration]
  end

  # "true" is not true - the flag is dropped to its default rather than guessed at.
  def test_a_non_boolean_is_error_is_dropped_not_coerced
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", resource_name: "checkout", is_error: "true")
    AgentCat.flush(timeout: 1)

    event = client.last_event
    assert_equal false, event[:is_error]
    assert_equal "checkout", event[:resource_name]
  end

  def test_non_hash_parameters_response_and_properties_are_wrapped_not_dropped
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(
      server, PROJECT_ID, session_id: "ses_t",
      parameters: "a string", response: 42, properties: [1, 2, 3]
    )
    AgentCat.flush(timeout: 1)

    event = client.last_event
    assert_equal({"value" => "a string"}, event[:parameters])
    assert_equal({"value" => 42}, event[:response])
    assert_equal [1, 2, 3], event[:properties]["value"]
  end

  def test_a_non_hash_error_becomes_a_message
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", error: "it broke")
    AgentCat.flush(timeout: 1)

    assert_equal({"message" => "it broke"}, client.last_event[:error])
  end

  def test_tags_are_validated_and_bad_entries_dropped_individually
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(
      server, PROJECT_ID, session_id: "ses_t",
      tags: {"good" => "value", "bad\nkey" => "x", "ok" => 12345}
    )
    AgentCat.flush(timeout: 1)

    assert_equal({"good" => "value"}, client.last_event[:tags])
  end

  def test_tags_that_are_not_a_hash_are_dropped_not_raised
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", tags: "not-a-hash")
    AgentCat.flush(timeout: 1)

    refute client.last_event.key?(:tags)
  end

  def test_the_trackers_redact_event_hook_applies
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_event: ->(event) {
      event.resource_name = "[redacted-name]"
      event
    })

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", resource_name: "secret-flow")
    AgentCat.flush(timeout: 1)

    assert_equal "[redacted-name]", client.last_event[:resource_name]
  end

  def test_the_trackers_redact_event_hook_can_drop_the_whole_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_event: ->(_event) {})

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t")
    AgentCat.flush(timeout: 1)

    assert_nil client.last_event
  end

  def test_the_trackers_redact_event_hook_cannot_change_system_fields
    server = build_server
    redactor = ->(event) {
      event.session_id = "ses_forged"
      event.project_id = "proj_someone_else"
      event.event_type = "mcp:tools/call"
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", resource_name: "checkout")
    AgentCat.flush(timeout: 1)

    event = client.last_event
    assert_equal "ses_t", event[:session_id]
    assert_equal PROJECT_ID, event[:project_id]
    assert_equal "agentcat:custom", event[:event_type]
  end

  # As in TS, the string hook is for captured tool traffic. A custom event
  # holds only what the customer chose to send, so it skips the hook.
  def test_the_trackers_redact_sensitive_information_hook_skips_custom_events
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: ->(string) { string.gsub("secret", "[x]") })

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", message: "contains a secret value")
    AgentCat.flush(timeout: 1)

    assert_equal "contains a secret value", client.last_event[:user_intent]
  end

  def test_the_string_form_bypasses_redaction_since_there_is_no_tracked_configuration
    server = build_server
    track(server, project_id: PROJECT_ID, redact_event: ->(event) {
      event.resource_name = "[redacted-name]"
      event
    })

    AgentCat.publish_custom_event("ses_bare", PROJECT_ID, resource_name: "should-stay-as-is")
    AgentCat.flush(timeout: 1)

    assert_equal "should-stay-as-is", posted.first[:resource_name]
  end

  def test_a_slow_redact_event_hook_does_not_delay_publish_custom_event_itself
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_event: ->(event) {
      sleep 0.3
      event
    }, hook_timeout: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", message: "hello")
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_operator elapsed, :<, 0.1, "publish_custom_event must not wait on redact_event itself"
    assert AgentCat.flush(timeout: 1), "queue should drain, not hang on the slow hook"
    assert_nil client.last_event
  end

  def test_a_failing_redact_sensitive_information_hook_does_not_drop_the_custom_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: ->(*) { raise "boom" })

    AgentCat.publish_custom_event(server, PROJECT_ID, session_id: "ses_t", message: "checkout done")
    AgentCat.flush(timeout: 1)

    assert_equal "checkout done", client.last_event[:user_intent]
  end

  def test_a_telemetry_only_tracked_server_still_reaches_its_exporters
    exported = []
    exporter = Object.new
    exporter.define_singleton_method(:call) { |event| exported << event }
    server = build_server
    client = track(server, project_id: nil, exporters: [exporter])

    AgentCat.publish_custom_event(server, nil, session_id: "ses_t", resource_name: "feature-usage")
    AgentCat.flush(timeout: 1)

    assert_nil client.last_event
    assert_equal 1, exported.size
    assert_equal "feature-usage", exported.first.resource_name
  end

  private

  def assert_silent_about_raising(&block)
    block.call
  rescue => e
    flunk "expected no exception, got #{e.class}: #{e.message}"
  end
end
