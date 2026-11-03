require_relative "test_helper"
require "json"
require "open3"
require "rbconfig"

# Test mode. The rest of the suite runs with AGENTCAT_ENABLED=true
# (test_helper.rb), so these tests unset it to see what a customer's suite sees.
class TestModeTest < Minitest::Test
  include AgentCatTestHelpers

  MODE_ENV = %w[AGENTCAT_ENABLED RAILS_ENV RACK_ENV APP_ENV AGENTCAT_DISABLE_DIAGNOSTICS].freeze

  def setup
    @saved_env = MODE_ENV.to_h { |name| [name, ENV.delete(name)] }
    AgentCat.reset!
    AgentCat::TestMode.reset!
    AgentCat::Diagnostics.http_post = nil
  end

  def teardown
    @saved_env.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    AgentCat.reset!
    AgentCat::TestMode.reset!
    AgentCat::Diagnostics.http_post = nil
  end

  # -- detection --------------------------------------------------------------------

  def test_minitest_is_a_test_environment_and_the_answer_is_a_real_boolean
    assert_same true, AgentCat::TestMode.test_environment?
  end

  def test_no_runner_and_no_env_is_not_a_test_environment
    assert_same false, AgentCat::TestMode.test_environment?(runner_loaded: false)
  end

  def test_rails_rack_and_app_env_test_or_testing_mean_a_test_environment
    %w[RAILS_ENV RACK_ENV APP_ENV].each do |name|
      ["test", " Testing "].each do |value|
        ENV[name] = value
        assert_same true, AgentCat::TestMode.test_environment?(runner_loaded: false), "#{name}=#{value.inspect}"
        ENV.delete(name)
      end
    end
    ENV["RAILS_ENV"] = "production"
    assert_same false, AgentCat::TestMode.test_environment?(runner_loaded: false)
  end

  # The old `$PROGRAM_NAME.end_with?("test")` rule matched bin/latest.
  def test_program_name_no_longer_decides
    out = run_ruby(<<~RUBY)
      $PROGRAM_NAME = "bin/latest"
      puts AgentCat::TestMode.test_environment?.inspect
    RUBY
    assert_equal "false", out.strip
  end

  def test_rspec_core_is_a_test_environment
    out = run_ruby(<<~RUBY)
      module RSpec; module Core; end; end
      puts AgentCat::TestMode.test_environment?.inspect
    RUBY
    assert_equal "true", out.strip
  end

  # The old sig said T::Boolean but returned `defined?(Minitest)`, a String: a TypeError.
  def test_diagnostics_see_the_test_environment_without_a_type_error
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "ruby", disabled: false)
    refute AgentCat::Diagnostics.enabled?
    assert_same true, AgentCat::Diagnostics.send(:test_environment?)
  end

  # -- AGENTCAT_ENABLED ---------------------------------------------------------------

  def test_unset_means_off_in_tests_and_on_elsewhere
    refute AgentCat::TestMode.sdk_enabled?
    assert AgentCat::TestMode.sdk_enabled?(runner_loaded: false)
  end

  def test_true_words_force_it_on_in_tests
    ["true", "1", " YES ", "on"].each do |word|
      ENV["AGENTCAT_ENABLED"] = word
      assert AgentCat::TestMode.sdk_enabled?, word.inspect
    end
  end

  def test_false_words_turn_it_off_everywhere
    ["false", "0", "No", " off "].each do |word|
      ENV["AGENTCAT_ENABLED"] = word
      refute AgentCat::TestMode.sdk_enabled?(runner_loaded: false), word.inspect
    end
  end

  def test_an_unknown_word_uses_the_default_and_warns_once
    lines = capture_log do
      ENV["AGENTCAT_ENABLED"] = "maybe"
      refute AgentCat::TestMode.sdk_enabled?
      assert AgentCat::TestMode.sdk_enabled?(runner_loaded: false)
    end
    assert_equal 1, lines.scan("AGENTCAT_ENABLED").size, lines
    assert_includes lines, "WARN"
  end

  def test_kill_switch_leaves_the_server_untouched_outside_tests
    out = run_ruby(<<~RUBY, "AGENTCAT_ENABLED" => "false")
      require "mcp"
      server = MCP::Server.new(name: "s", tools: [])
      puts(AgentCat.track(server).equal?(server))
      puts AgentCat.tracked?(server).inspect
    RUBY
    assert_equal "true\nfalse", out.strip
  end

  # -- test mode without the fake --------------------------------------------------------

  def test_track_in_a_test_environment_does_nothing
    server = build_server
    client = RecordingClient.new

    returned = AgentCat.track(server, PROJECT_ID, AgentCat::Options.new(client: client))
    assert_same server, returned
    refute AgentCat.tracked?(server)
    refute_includes listed_tool(server, "echo").dig(:inputSchema, :properties).keys.map(&:to_s), "session_id"

    call_tool(server, "echo", {msg: "hi"})
    AgentCat.flush(timeout: 1)
    assert_empty client.events
  end

  def test_track_in_a_test_environment_sends_no_diagnostics
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    calls = []
    AgentCat::Diagnostics.http_post = ->(*args) { calls << args && [200, ""] }

    AgentCat.track(build_server, PROJECT_ID)
    AgentCat.flush(timeout: 1)

    refute AgentCat::Diagnostics.enabled?
    assert_empty calls
  end

  def test_publish_custom_event_in_a_test_environment_does_nothing
    AgentCat.publish_custom_event("ses_1", PROJECT_ID, resource_name: "job")
    assert_nil AgentCat.instance_variable_get(:@event_queue), "nothing was queued"
  end

  # -- AgentCat.fake ---------------------------------------------------------------------

  def test_fake_records_tool_calls_instead_of_sending_them
    fake = AgentCat.fake
    assert_instance_of AgentCat::Testing::Fake, fake
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi"})

    assert_equal 1, fake.events.size
    event = fake.events.first
    assert_equal "mcp:tools/call", event[:event_type]
    assert_equal "echo", event[:resource_name]
    assert_equal PROJECT_ID, event[:project_id]
    assert_empty client.events, "the fake sends nothing"
    fake.assert_tracked
    fake.assert_tracked("echo")
    fake.assert_tracked("echo", count: 1)
    fake.assert_tracked { |e| e[:parameters]["arguments"]["msg"] == "hi" }
    fake.assert_tracked_count(1)
  end

  def test_fake_records_after_hooks_and_redaction
    fake = AgentCat.fake
    server = build_server
    track(server, project_id: PROJECT_ID, redact_event: ->(event) {
      event.resource_name = "renamed"
      event
    })

    tool_result(server, "echo", {msg: "hi"})

    fake.assert_tracked("renamed")
  end

  def test_fake_records_telemetry_only_servers_and_skips_exporters
    exported = []
    fake = AgentCat.fake
    server = build_server
    track(server, exporters: [->(event) { exported << event }])

    tool_result(server, "echo", {msg: "hi"})

    fake.assert_tracked_count(1)
    assert_empty exported
  end

  def test_fake_records_custom_events
    fake = AgentCat.fake
    server = build_server
    track(server, project_id: PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, resource_name: "checkout")
    AgentCat.publish_custom_event("ses_1", PROJECT_ID, resource_name: "webhook")

    fake.assert_custom_event_published
    fake.assert_custom_event_published("checkout")
    fake.assert_custom_event_published { |e| e[:session_id] == "ses_1" }
    fake.assert_tracked_count(0)
    assert_equal 2, fake.events.size
  end

  def test_fake_records_even_with_the_kill_switch
    ENV["AGENTCAT_ENABLED"] = "false"
    fake = AgentCat.fake
    server = build_server
    track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi"})

    fake.assert_tracked("echo")
  end

  def test_fake_sends_no_diagnostics
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    ENV["AGENTCAT_ENABLED"] = "true"
    calls = []
    AgentCat::Diagnostics.http_post = ->(*args) { calls << args && [200, ""] }
    AgentCat.fake

    track(build_server, project_id: PROJECT_ID)
    AgentCat.flush(timeout: 1)

    refute AgentCat::Diagnostics.enabled?
    assert_empty calls
  end

  def test_failed_assertions_raise_minitest_assertion
    fake = AgentCat.fake
    server = build_server
    track(server, project_id: PROJECT_ID)
    tool_result(server, "echo", {msg: "hi"})

    error = assert_raises(Minitest::Assertion) { fake.assert_tracked("other") }
    assert_includes error.message, "other"
    assert_raises(Minitest::Assertion) { fake.assert_tracked("echo", count: 2) }
    assert_raises(Minitest::Assertion) { fake.assert_tracked_count(2) }
    assert_raises(Minitest::Assertion) { fake.assert_nothing_tracked }
    assert_raises(Minitest::Assertion) { fake.assert_custom_event_published }
  end

  def test_assert_nothing_tracked_passes_on_an_empty_fake
    AgentCat.fake.assert_nothing_tracked
  end

  def test_a_server_tracked_before_the_fake_is_not_tracked_and_the_failure_says_so
    server = build_server
    AgentCat.track(server, PROJECT_ID)
    fake = AgentCat.fake
    call_tool(server, "echo", {msg: "hi"})

    error = assert_raises(Minitest::Assertion) { fake.assert_tracked }
    assert_includes error.message, "call AgentCat.fake before AgentCat.track"
  end

  def test_reset_removes_the_fake
    AgentCat.fake
    AgentCat.reset!
    assert_nil AgentCat.active_fake
    refute AgentCat::TestMode.sdk_enabled?
  end

  def test_without_minitest_assertions_raise_a_plain_error
    out = run_ruby(<<~RUBY)
      fake = AgentCat.fake
      begin
        fake.assert_tracked
      rescue => e
        puts e.class
        puts e.is_a?(StandardError)
      end
    RUBY
    assert_equal "AgentCat::Testing::AssertionError\ntrue", out.strip
  end

  def test_under_rspec_assertions_raise_an_expectation_failure
    out = run_ruby(<<~RUBY)
      module RSpec; module Core; end; module Expectations; class ExpectationNotMetError < Exception; end; end; end
      begin
        AgentCat.fake.assert_tracked
      rescue Exception => e
        puts e.class
      end
    RUBY
    assert_equal "RSpec::Expectations::ExpectationNotMetError", out.strip
  end

  private

  # A fresh Ruby without Minitest, so only what the script sets decides test mode.
  def run_ruby(script, env = {})
    clean = MODE_ENV.to_h { |name| [name, nil] }.merge(env)
    lib = File.expand_path("../lib", __dir__)
    out, err, status = Open3.capture3(clean, RbConfig.ruby, "-I", lib, "-e",
      "require 'agentcat'\nAgentCat.logger = Logger.new(File::NULL)\n#{script}")
    assert status.success?, err
    out
  end

  def capture_log
    io = StringIO.new
    original = AgentCat.logger
    AgentCat.logger = Logger.new(io)
    yield
    io.string
  ensure
    AgentCat.logger = original
  end
end
