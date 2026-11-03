require_relative "test_helper"

class HooksTest < Minitest::Test
  include AgentCatTestHelpers

  # --- hook_timeout option ---

  def test_hook_timeout_defaults_to_one_second
    assert_equal 1.0, AgentCat::Options.new.hook_timeout
  end

  def test_hook_timeout_is_capped_at_five_seconds
    assert_equal 5.0, AgentCat::Options.new(hook_timeout: 100).hook_timeout
  end

  # Bad option values log one WARN line and use the default.
  def test_non_positive_hook_timeout_warns_and_uses_the_default
    [0, -1].each do |bad|
      options = nil
      log = capture_log { options = AgentCat::Options.new(hook_timeout: bad) }

      assert_equal 1.0, options.hook_timeout
      assert_equal ["WARN: Options#hook_timeout must be a positive number, got #{bad}; using the default 1.0"], log.lines(chomp: true)
    end
  end

  def test_non_callable_hook_warns_and_is_dropped
    options = nil
    log = capture_log { options = AgentCat::Options.new(event_tags: "not-a-callable", identify: ->(*) {}) }

    assert_nil options.event_tags
    refute_nil options.identify
    assert_equal ["WARN: Options#event_tags must respond to #call, got String; the hook is ignored"], log.lines(chomp: true)
  end

  def test_a_dropped_hook_does_not_stop_the_server_from_being_tracked
    server = build_server
    client = nil
    capture_log { client = track(server, project_id: PROJECT_ID, event_tags: 42) }

    refute tool_result(server, "echo", {msg: "hi"})[:isError]
    assert_equal "echo", client.last_event[:resource_name]
  end

  # --- event_tags ---

  def test_event_tags_are_attached_to_event
    server = build_server
    tags = ->(*) { {"env" => "prod", "team" => "payments"} }
    client = track(server, project_id: PROJECT_ID, event_tags: tags)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "prod", client.last_event[:tags]["env"]
    assert_equal "payments", client.last_event[:tags]["team"]
  end

  def test_event_tags_receives_a_tool_call
    server = build_server
    seen = nil
    tags = ->(tool_call) {
      seen = [tool_call.arguments["msg"], tool_call]
      {}
    }
    track(server, project_id: PROJECT_ID, event_tags: tags)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "hello", seen[0]
    assert_instance_of AgentCat::ToolCall, seen[1]
    assert_equal "echo", seen[1].tool_name
  end

  def test_event_tags_wrong_shape_is_ignored
    server = build_server
    client = track(server, project_id: PROJECT_ID, event_tags: ->(*) { [:not, :a, :hash] })

    tool_result(server, "echo", {msg: "hello"})

    assert_equal(["agentcat_session_id_source"], client.last_event[:tags].keys)
  end

  def test_failing_event_tags_does_not_break_call_or_drop_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, event_tags: ->(*) { raise "boom" })

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal "hello", texts_of(result).last
    assert_equal 1, client.events.size
  end

  def test_event_tags_drops_invalid_entries_individually_matching_agentcat_api
    server = build_server
    tags = ->(*) {
      {
        "env" => "prod",
        "deploy region" => "allowed, spaces are part of the agentcat-api charset",
        ("k" * 33) => "too long a key",
        "bad key!" => "not in the allowed charset",
        "newline" => "line one\nline two",
        "value_too_long" => "v" * 201
      }
    }
    client = track(server, project_id: PROJECT_ID, event_tags: tags)

    tool_result(server, "echo", {msg: "hello"})

    result = client.last_event[:tags]
    assert_equal "prod", result["env"]
    assert_equal "allowed, spaces are part of the agentcat-api charset", result["deploy region"]
    refute result.key?("k" * 33)
    refute result.key?("bad key!")
    refute result.key?("newline")
    refute result.key?("value_too_long")
  end

  def test_event_tags_caps_at_fifty_entries
    server = build_server
    tags = ->(*) { (1..75).map { |i| ["tag#{i}", "v#{i}"] }.to_h }
    client = track(server, project_id: PROJECT_ID, event_tags: tags)

    tool_result(server, "echo", {msg: "hello"})

    result = client.last_event[:tags]
    kept = result.select { |key, _| key.start_with?("tag") }
    assert_equal 50, kept.size
    assert_equal "v1", kept["tag1"]
    assert_equal "v50", kept["tag50"]
    refute kept.key?("tag51")
    # the customer cap doesn't squeeze out the SDK's own tag
    assert result.key?("agentcat_session_id_source")
  end

  # --- event_properties ---

  def test_event_properties_are_merged
    server = build_server
    props = ->(tool_call) { {"source" => tool_call.arguments["msg"]} }
    client = track(server, project_id: PROJECT_ID, event_properties: props)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "hello", client.last_event[:properties]["source"]
  end

  def test_event_properties_wrong_shape_is_ignored
    server = build_server
    client = track(server, project_id: PROJECT_ID, event_properties: ->(*) { "nope" })

    tool_result(server, "echo", {msg: "hello"})

    refute client.last_event[:properties].key?("source")
  end

  def test_event_properties_cannot_clobber_reserved_health_signals
    server = build_server
    props = ->(*) { {"agentcat_context_supplied" => "overridden"} }
    client = track(server, project_id: PROJECT_ID, event_properties: props)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal false, client.last_event[:properties]["agentcat_context_supplied"]
  end

  # --- redact_event ---

  def test_redact_event_can_mutate_and_return_event
    server = build_server
    redactor = ->(event) {
      event.parameters = event.parameters.merge("audit" => "true")
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "true", client.last_event[:parameters]["audit"]
  end

  def test_redact_event_returning_nil_drops_the_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_event: ->(_event) {})

    tool_result(server, "echo", {msg: "hello"})

    assert_empty client.events
  end

  def test_redact_event_sees_raw_values_before_sensitive_redaction
    server = build_server
    order = []
    redact_event = ->(event) {
      order << :event
      event
    }
    redact_sensitive = ->(value) {
      order << :string
      value
    }
    client = track(server, project_id: PROJECT_ID,
      redact_event: redact_event,
      redact_sensitive_information: redact_sensitive)

    tool_result(server, "echo", {msg: "hello"})

    # redact_event runs first (sees raw values), then redact_sensitive_information
    # is applied per string across the whole event.
    assert_equal [:event, :string], order.first(2)
    assert_operator order.count(:string), :>=, 2
    assert_equal 1, client.events.size
  end

  def test_redact_event_returning_wrong_type_is_ignored
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_event: ->(_event) { "garbage" })

    tool_result(server, "echo", {msg: "hello"})

    assert_equal 1, client.events.size
  end

  def test_redact_event_detached_object_drops_unset_fields_with_warning
    server = build_server
    messages = []
    redactor = ->(event) {
      AgentCat::UnredactedEvent.new(
        project_id: event.project_id, id: event.id, event_type: event.event_type,
        resource_name: event.resource_name, parameters: event.parameters,
        duration: event.duration, timestamp: event.timestamp,
        agentcat_version: event.agentcat_version
      )
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    logs_default = AgentCat.logger
    AgentCat.logger.method(:warn)
    AgentCat.logger = Logger.new(File::NULL).tap { |l| l.define_singleton_method(:warn) { |msg| messages << msg } }
    tool_result(server, "echo", {msg: "hello"})
    AgentCat.logger = logs_default

    assert_match(/mutate and return the same UnredactedEvent/i, messages.join)
    assert_equal 1, client.events.size
  end

  # Same five fields TS and Go put back after the hook.
  def test_redact_event_cannot_change_system_fields
    server = build_server
    redactor = ->(event) {
      event.id = "evt_forged"
      event.session_id = "ses_forged"
      event.project_id = "proj_someone_else"
      event.event_type = "agentcat:custom"
      event.timestamp = "1999-01-01T00:00:00.000Z"
      event.resource_name = "renamed"
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    tool_result(server, "echo", {msg: "hello"})

    event = client.last_event
    assert_match(/\Aevt_/, event[:id])
    refute_equal "evt_forged", event[:id]
    refute_equal "ses_forged", event[:session_id]
    assert_equal PROJECT_ID, event[:project_id]
    assert_equal "mcp:tools/call", event[:event_type]
    refute_equal "1999-01-01T00:00:00.000Z", event[:timestamp]
    # Everything else is still the hook's call.
    assert_equal "renamed", event[:resource_name]
  end

  def test_redact_event_cannot_clear_system_fields
    server = build_server
    seen = {}
    redactor = ->(event) {
      seen[:session_id] = event.session_id
      event.session_id = nil
      event.project_id = nil
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    tool_result(server, "echo", {msg: "hello"})

    refute_nil seen[:session_id]
    assert_equal seen[:session_id], client.last_event[:session_id]
    assert_equal PROJECT_ID, client.last_event[:project_id]
  end

  def test_redact_event_detached_object_still_gets_system_fields_back
    server = build_server
    original = {}
    redactor = ->(event) {
      original[:id] = event.id
      original[:session_id] = event.session_id
      AgentCat::UnredactedEvent.new(
        id: "evt_forged", event_type: "agentcat:custom", resource_name: event.resource_name,
        parameters: event.parameters, duration: event.duration,
        timestamp: "1999-01-01T00:00:00.000Z", agentcat_version: event.agentcat_version
      )
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    tool_result(server, "echo", {msg: "hello"})

    event = client.last_event
    assert_equal original[:id], event[:id]
    assert_equal original[:session_id], event[:session_id]
    assert_equal PROJECT_ID, event[:project_id]
    assert_equal "mcp:tools/call", event[:event_type]
  end

  # A hook that mutates in place and then returns junk still kept the event (it's
  # ignored, not dropped), so its in-place edits to system fields must not survive either.
  def test_redact_event_returning_wrong_type_still_gets_system_fields_back
    server = build_server
    redactor = ->(event) {
      event.project_id = "proj_someone_else"
      "garbage"
    }
    client = track(server, project_id: PROJECT_ID, redact_event: redactor)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal PROJECT_ID, client.last_event[:project_id]
  end

  # --- redact_sensitive_information ---

  def test_redact_sensitive_information_scrubs_string_values
    server = build_server
    redact = ->(value) { value.gsub(/secret=\d+/, "secret=[REDACTED]") }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact)

    tool_result(server, "echo", {msg: "token secret=12345"})

    assert_equal "token secret=[REDACTED]", client.last_event[:parameters]["arguments"]["msg"]
  end

  def test_redact_sensitive_information_applies_to_nested_structures
    tool = MCP::Tool.define(
      name: "reflect",
      description: "Returns whatever payload is passed",
      input_schema: {type: "object", properties: {payload: {}}, required: ["payload"]}
    ) do |payload:, server_context: nil|
      MCP::Tool::Response.new([{type: "text", text: payload.to_json}])
    end
    server = MCP::Server.new(name: "nested-server", version: "1.0.0", tools: [tool])
    redact = ->(value) { value.gsub(/secret=\d+/, "[REDACTED]") }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact,
      event_properties: ->(*) { {"note" => "inner secret=99"} })

    tool_result(server, "reflect", {payload: {nested: "a secret=1 b", list: ["secret=2", 42]}})

    event = client.last_event
    assert_equal({nested: "a [REDACTED] b", list: ["[REDACTED]", 42]}, event[:parameters]["arguments"]["payload"])
  end

  # TS parity (`PROTECTED_FIELDS` in its redaction.ts): `properties` is the customer's
  # own metadata, so the string hook leaves it alone.
  def test_redact_sensitive_information_leaves_properties_alone
    server = build_server
    redact = ->(value) { value.gsub(/secret=\d+/, "[REDACTED]") }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact,
      event_properties: ->(*) { {"note" => "inner secret=99"} })

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "inner secret=99", client.last_event[:properties]["note"]
  end

  def test_redact_sensitive_information_applies_to_identify_data
    server = build_server
    redact = ->(value) { value.gsub(/secret=\d+/, "[REDACTED]") }
    identify = ->(*) {
      AgentCat::UserIdentity.new(user_id: "user-1", user_name: "Ann", user_data: {"email" => "ann secret=7", "nested" => {"list" => ["secret=8", 3]}})
    }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact, identify: identify)

    tool_result(server, "echo", {msg: "hello"})

    event = client.last_event
    assert_equal({"email" => "ann [REDACTED]", "nested" => {"list" => ["[REDACTED]", 3]}}, event[:identify_data])
    # Identity fields stay as they are, same as TS.
    assert_equal "user-1", event[:identify_actor_given_id]
    assert_equal "Ann", event[:identify_actor_name]
  end

  def test_redact_sensitive_information_applies_to_the_error
    failing = echo_tool(name: "fails") do |msg:, server_context: nil|
      raise "root secret=1"
    rescue
      raise ArgumentError, "wrapper secret=2 for #{msg}"
    end
    server = build_server(tools: [failing])
    redact = ->(value) { value.gsub(/secret=\d+/, "[REDACTED]").gsub("test_hooks", "[FILE]") }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact)

    call_tool(server, "fails", {msg: "secret=3"})
    AgentCat.flush(timeout: 1)

    error = client.last_event[:error]
    assert_equal "wrapper [REDACTED] for [REDACTED]", error["message"]
    refute_includes error["stack"], "test_hooks"
    assert error["frames"].none? { |frame| frame["filename"].to_s.include?("test_hooks") }
    assert(error["frames"].all? { |frame| frame["lineno"].is_a?(Integer) }, "non-strings stay as they are")
    assert_equal ["root [REDACTED]"], error["chained_errors"].map { |chained| chained["message"] }
  end

  def test_redact_sensitive_information_applies_to_user_intent
    server = build_server
    redact = ->(value) { value.gsub(/secret=\d+/, "[REDACTED]") }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact)

    tool_result(server, "echo", {msg: "hello", context: "task secret=42"})

    assert_equal "task [REDACTED]", client.last_event[:user_intent]
  end

  # If the hook fails on any string we can't tell what's still raw, so the whole event
  # is dropped rather than sent with that string unredacted.
  def test_failing_redact_sensitive_information_drops_the_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: ->(*) { raise "boom" })

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal "hello", texts_of(result).last
    assert_empty client.events
  end

  def test_timed_out_redact_sensitive_information_drops_the_event
    server = build_server
    slow = ->(text) {
      sleep 0.3
      text.gsub("secret", "[REDACTED]")
    }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: slow, hook_timeout: 0.05)

    tool_result(server, "echo", {msg: "my secret"})

    assert_empty client.events
  end

  def test_redact_sensitive_information_returning_a_non_string_drops_the_event
    server = build_server
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: ->(*) {})

    tool_result(server, "echo", {msg: "hello"})

    assert_empty client.events
  end

  # One bad string is enough - the strings that did get redacted don't save the event.
  def test_redact_sensitive_information_failing_on_one_string_drops_the_event
    server = build_server
    redact = ->(text) {
      raise "can't handle this one" if text.include?("secret")
      text
    }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact)

    tool_result(server, "echo", {msg: "hello"})
    assert_equal 1, client.events.size

    tool_result(server, "echo", {msg: "my secret"})
    assert_equal 1, client.events.size
  end

  def test_dropping_on_failed_redaction_skips_exporters_too
    server = build_server
    exported = []
    exporter = ->(event) { exported << event }
    client = track(server, project_id: PROJECT_ID, exporters: [exporter], redact_sensitive_information: ->(*) { raise "boom" })

    tool_result(server, "echo", {msg: "hello"})

    assert_empty client.events
    assert_empty exported
  end

  # --- hook timeout behaviour ---

  def test_slow_hook_is_capped_and_does_not_break_the_call
    server = build_server
    slow = ->(*) {
      sleep 0.3
      AgentCat::UserIdentity.new(user_id: "late")
    }
    client = track(server, project_id: PROJECT_ID, stateless: true, identify: slow, hook_timeout: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    result = tool_result(server, "echo", {msg: "hello"})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    assert_equal ["hello"], texts_of(result)
    assert_nil client.last_event[:actor_id]
    assert_operator elapsed, :<, 0.25, "call should not be delayed by the full hook sleep"
  end

  # Redaction (both hooks) runs after the job is enqueued, not before - matching
  # Go/TS/Python, so a slow or uncached redact hook costs the background queue time,
  # never the tool call's own response. Measures `call_tool` directly, not
  # `tool_result` (which also waits on `AgentCat.flush`), so the slow hook has nowhere
  # to hide inside the measured window.
  def test_slow_redact_hook_does_not_delay_the_tool_calls_response
    server = build_server
    redact = ->(*) {
      sleep 0.3
      "x"
    }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact, hook_timeout: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = call_tool(server, "echo", {msg: "hello"})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_nil response[:result]
    assert_operator elapsed, :<, 0.1, "the call must not wait on redact_sensitive_information - it now runs after enqueue"

    # The hook is still capped once it actually runs, asynchronously - the queue drains
    # instead of hanging, and the timed-out redaction drops the event.
    assert AgentCat.flush(timeout: 1), "queue should drain, not hang on the slow hook"
    assert_empty client.events
  end

  def test_slow_redact_event_hook_does_not_delay_the_tool_calls_response
    server = build_server
    slow_redact_event = ->(event) {
      sleep 0.3
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: slow_redact_event, hook_timeout: 0.05)

    started = Process.clock_gettime(Process::CLOCK_MONOTONIC)
    response = call_tool(server, "echo", {msg: "hello"})
    elapsed = Process.clock_gettime(Process::CLOCK_MONOTONIC) - started

    refute_nil response[:result]
    assert_operator elapsed, :<, 0.1, "the call must not wait on redact_event - it now runs after enqueue"

    # A hook that times out is treated the same as one that explicitly returns nil -
    # costs this event, same pre-existing rule as a hook that raises (see "Both
    # redaction hooks" in Options). The call itself already returned fine above;
    # this just confirms the worker doesn't hang waiting on it either.
    AgentCat.flush(timeout: 1)
    assert_equal 0, client.events.size
  end

  def test_all_hooks_run_with_default_timeout
    server = build_server
    calls = []
    track(server, project_id: PROJECT_ID,
      identify: ->(_tool_call) {
        calls << :identify
        AgentCat::UserIdentity.new(user_id: "u")
      },
      event_tags: ->(_tool_call) {
        calls << :tags
        {}
      },
      event_properties: ->(_tool_call) {
        calls << :props
        {}
      },
      redact_event: ->(e) {
        calls << :event
        e
      },
      redact_sensitive_information: ->(s) {
        calls << :string
        s
      })

    tool_result(server, "echo", {msg: "hello"})

    # redact_sensitive_information runs per string; only its first invocation matters for ordering.
    assert_equal [:identify, :tags, :props, :event, :string], calls.first(5)
    assert_operator calls.count(:string), :>=, 2
  end

  # --- callable forms ---

  def test_hook_accepts_callable_object
    callable = Class.new do
      def call(_tool_call)
        {"env" => "callable"}
      end
    end.new
    server = build_server
    client = track(server, project_id: PROJECT_ID, event_tags: callable)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "callable", client.last_event[:tags]["env"]
  end
end
