require_relative "test_helper"
require "minitest/mock"

class TrackTest < Minitest::Test
  include AgentCatTestHelpers

  def test_returns_the_server_and_records_a_tracker
    server = build_server
    options = AgentCat::Options.new

    assert_same server, AgentCat.track(server, PROJECT_ID, options)
    assert AgentCat.tracked?(server)
    assert_equal PROJECT_ID, AgentCat.tracker_for(server).project_id
    assert_same options, AgentCat.tracker_for(server).options
  end

  def test_track_is_idempotent
    server = build_server
    AgentCat.track(server, PROJECT_ID)
    before = server.tools.transform_values(&:object_id)

    AgentCat.track(server, PROJECT_ID)

    assert_equal before, server.tools.transform_values(&:object_id)
    assert_equal 1, list_tools(server).count { |tool| tool[:name] == "get_more_tools" }
    assert_equal 1, listed_tool(server, "echo")[:inputSchema][:properties].keys.count(:context)
  end

  # The README's per-request pattern tracks a fresh server on every request. The
  # registry must not keep them alive. Conservative stack scanning can keep a few, so
  # this allows some survivors.
  def test_servers_tracked_per_request_are_collected
    registry = AgentCat.instance_variable_get(:@trackers)
    servers = track_servers(200)
    GC.start
    assert_equal 200, registry.size, "the servers are tracked while they live"

    servers.clear
    4.times { GC.start(full_mark: true, immediate_sweep: true) }

    assert_operator registry.size, :<, 50, "dropped servers must be collected"
  end

  def test_a_live_tracked_server_keeps_its_tracker_across_gc
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    4.times { GC.start(full_mark: true, immediate_sweep: true) }

    assert AgentCat.tracked?(server)
    call_tool(server, "echo", {msg: "hi"})
    AgentCat.flush(timeout: 1)
    assert_equal "echo", client.last_event[:resource_name]
  end

  def test_reset_forgets_tracked_servers
    server = build_server
    AgentCat.track(server)

    AgentCat.reset!

    refute AgentCat.tracked?(server)
    assert_nil AgentCat._tracking_data(server)
  end

  # As in TS, a malformed project ID logs one WARN line and is sent as
  # given. The AgentCat API is the authority on what a project ID looks like.
  def test_malformed_project_id_warns_once_and_is_sent_as_given
    server = build_server
    client = RecordingClient.new
    log = capture_log do
      assert_same server, AgentCat.track(server, "proj_demo", AgentCat::Options.new(client: client))
    end

    assert AgentCat.tracked?(server)
    assert_equal "proj_demo", AgentCat.tracker_for(server).project_id
    assert_equal 1, log.lines.count { |line| line.include?("proj_demo") }
    assert_match(/\AWARN: .*proj_demo.*proj_ followed by 27 letters or digits/, log)

    call_tool(server, "echo", {msg: "hi"})
    AgentCat.flush(timeout: 1)
    assert_equal "proj_demo", client.last_event[:project_id]
  end

  def test_valid_project_id_logs_no_warning
    log = capture_log(level: Logger::WARN) { AgentCat.track(build_server, PROJECT_ID) }

    assert_empty log
  end

  def test_empty_and_blank_project_ids_mean_telemetry_only
    ["", "   ", "\t\n"].each do |blank|
      AgentCat.reset!
      server = build_server
      exported = []
      client = track(server, project_id: blank, exporters: [->(event) { exported << event }])

      call_tool(server, "echo", {msg: "hi"})
      AgentCat.flush(timeout: 1)

      assert_nil AgentCat.tracker_for(server).project_id, blank.inspect
      assert_empty client.events, "#{blank.inspect} must not deliver to AgentCat"
      assert_equal 1, exported.size, "#{blank.inspect} still exports"
    end
  end

  def test_nil_project_id_does_not_read_the_environment
    previous = ENV["AGENTCAT_PROJECT_ID"]
    ENV["AGENTCAT_PROJECT_ID"] = PROJECT_ID
    server = build_server
    client = track(server)

    call_tool(server, "echo", {msg: "hi"})
    AgentCat.flush(timeout: 1)

    assert_nil AgentCat.tracker_for(server).project_id
    assert_empty client.events
  ensure
    ENV["AGENTCAT_PROJECT_ID"] = previous
  end

  # `track` changes no first-wins process-wide setting until it knows it tracks
  # the server, so a `track` that goes nowhere can't lock in its client settings.
  def test_a_track_that_goes_nowhere_leaves_the_client_settings_free
    AgentCat::Client.reset_timeout!
    AgentCat::Client.reset_base_url!
    AgentCat.track(Object.new, PROJECT_ID, AgentCat::Options.new(request_timeout: 3, api_base_url: "https://wrong.example.com"))

    assert_equal AgentCat::Client::DEFAULT_READ_TIMEOUT_SECONDS.to_f, AgentCat::Client.read_timeout_seconds
    refute_equal "https://wrong.example.com", AgentCat::Client.api_url

    AgentCat.track(build_server, PROJECT_ID, AgentCat::Options.new(request_timeout: 4, api_base_url: "https://right.example.com"))

    assert_equal 4.0, AgentCat::Client.read_timeout_seconds
    assert_equal "https://right.example.com", AgentCat::Client.api_url
  ensure
    AgentCat::Client.reset_timeout!
    AgentCat::Client.reset_base_url!
  end

  def test_a_failing_setup_returns_the_server_logs_an_error_and_changes_nothing
    AgentCat::Client.reset_timeout!
    server = build_server
    broken = Class.new(AgentCat::Adapters::Official) do
      def initialize(_server)
        raise "adapter exploded"
      end
    end
    log = nil
    AgentCat.stub(:detect_adapter, broken) do
      log = capture_log { assert_same server, AgentCat.track(server, PROJECT_ID, AgentCat::Options.new(request_timeout: 3)) }
    end

    refute AgentCat.tracked?(server)
    assert_match(/\AERROR: AgentCat setup failed, the server is not tracked: RuntimeError: adapter exploded/, log)
    assert_equal AgentCat::Client::DEFAULT_READ_TIMEOUT_SECONDS.to_f, AgentCat::Client.read_timeout_seconds
  ensure
    AgentCat::Client.reset_timeout!
  end

  def test_unknown_servers_are_returned_untouched
    server = Object.new

    assert_same server, AgentCat.track(server, PROJECT_ID)
    refute AgentCat.tracked?(server)
  end

  def test_nil_options_use_defaults
    server = build_server

    AgentCat.track(server, nil, nil)

    assert_kind_of AgentCat::Options, AgentCat.tracker_for(server).options
  end

  def test_tools_can_still_be_defined_after_tracking
    server = build_server
    AgentCat.track(server)

    server.define_tool(name: "later", description: "Added after track", input_schema: {type: "object", properties: {}}) { |**| MCP::Tool::Response.new([]) }

    assert_equal %w[echo get_more_tools later], list_tools(server).map { |tool| tool[:name] }.sort
  end

  def test_instrumentation_failure_does_not_raise
    server = build_server
    server.tools["broken"] = Object.new

    assert_same server, AgentCat.track(server, PROJECT_ID)
    assert AgentCat.tracked?(server)
  end

  def test_flush_returns_true_when_theres_nothing_queued
    assert_equal true, AgentCat.flush(timeout: 0)
  end

  def test_flush_waits_for_a_real_publish_to_drain
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    call_tool(server, "echo", {msg: "hi"})

    assert_equal true, AgentCat.flush(timeout: 1)
    refute_nil client.last_event
  end

  private

  # In its own method so no local in the test body still points at a server.
  def track_servers(count)
    options = AgentCat::Options.new(client: RecordingClient.new)
    Array.new(count) { AgentCat.track(build_server, PROJECT_ID, options) }
  end
end
