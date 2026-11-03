require_relative "test_helper"
require "minitest/mock"

# Lost events and exporter setup failures log at ERROR, hook failures and
# ignored customer data at WARN. A line that repeats per event logs once per window
# (see test_log.rb), and no line at WARN or ERROR carries a payload value.
class LogLevelsTest < Minitest::Test
  include AgentCatTestHelpers

  SECRET = "s3cret-payload-value"

  class FailingClient
    def post_event(_event) = nil
  end

  class BrokenExporter
    def export(_event) = raise(ArgumentError, SECRET)
  end

  def test_a_lost_event_logs_one_error_line_however_often_it_happens
    log = capture_log(level: Logger::WARN) do
      2.times { AgentCat::Delivery.publish(FailingClient.new, {project_id: PROJECT_ID}, max_retries: 1, base_delay: 0.001) }
    end

    assert_equal ["ERROR: event publish failed after 2 attempts; the event is lost"], log.lines(chomp: true)
  end

  def test_a_publish_failure_logs_an_error_with_the_status_and_not_the_response_body
    api = Object.new
    api.define_singleton_method(:publish_event) do |**|
      raise AgentCatApi::ApiError.new(code: 400, response_body: SECRET)
    end
    log = AgentCat::Client.stub(:events_api, api) do
      capture_log { assert_nil AgentCat::Client.post_event({project_id: PROJECT_ID}) }
    end

    assert_includes log, "ERROR: failed to publish event to AgentCat: AgentCatApi::ApiError (HTTP 400)"
    refute log.lines.any? { |line| line.start_with?("ERROR", "WARN") && line.include?(SECRET) }
  end

  def test_a_full_queue_logs_an_error
    queue = AgentCat::EventQueue.new(max_size: 1)
    blocker = Queue.new
    log = capture_log(level: Logger::WARN) do
      queue.enqueue { blocker.pop }
      sleep 0.05 until queue.size.zero?
      3.times { queue.enqueue {} }
    end
    blocker << :go

    assert_equal ["ERROR: event queue is full (1 events); dropped the oldest event"], log.lines(chomp: true)
  ensure
    queue&.shutdown
  end

  def test_an_exporter_failure_logs_an_error_naming_the_exporter_only
    exporter = BrokenExporter.new
    server = build_server
    log = capture_log(level: Logger::WARN) do
      track(server, project_id: PROJECT_ID, exporters: [exporter])
      2.times { tool_result(server, "echo", {msg: "hi"}) }
    end

    assert_equal ["ERROR: exporter LogLevelsTest::BrokenExporter failed with ArgumentError; the event was not exported"], log.lines(chomp: true)
  end

  def test_a_hook_that_raises_logs_a_warning_naming_the_hook_and_class_only
    server = build_server
    log = capture_log(level: Logger::WARN) do
      track(server, project_id: PROJECT_ID, event_tags: ->(*) { raise SECRET })
      tool_result(server, "echo", {msg: "hi"})
    end

    assert_equal ["WARN: event_tags hook raised RuntimeError"], log.lines(chomp: true)
  end

  def test_a_hook_that_times_out_logs_a_warning
    server = build_server
    log = capture_log(level: Logger::WARN) do
      track(server, project_id: PROJECT_ID, event_properties: ->(*) { sleep 1 }, hook_timeout: 0.05)
      tool_result(server, "echo", {msg: "hi"})
    end

    assert_equal ["WARN: event_properties hook timed out after 0.05s"], log.lines(chomp: true)
  end

  def test_dropped_tags_log_a_warning_with_counts_not_values
    server = build_server
    client = nil
    tags = {"ok" => "fine", "bad\nkey" => SECRET, "bad_value" => "line\n#{SECRET}"}
    log = capture_log(level: Logger::WARN) do
      client = track(server, project_id: PROJECT_ID, event_tags: ->(*) { tags })
      tool_result(server, "echo", {msg: "hi"})
    end

    assert_equal({"ok" => "fine"}, client.last_event[:tags].slice("ok", "bad_value"))
    assert_match(/\AWARN: event_tags: dropped 2 invalid \(/, log)
    assert_equal 1, log.lines.size
    refute_includes log, SECRET
  end

  def test_tags_of_the_wrong_type_log_a_warning
    log = capture_log { AgentCat::Tags.sanitize([SECRET], "event_tags") }

    assert_equal ["WARN: event_tags: expected a Hash of tags, got Array; ignored"], log.lines(chomp: true)
  end

  def test_ignored_hook_results_log_a_warning
    server = build_server
    log = capture_log(level: Logger::WARN) do
      track(server, project_id: PROJECT_ID,
        redact_event: ->(_event) { SECRET },
        event_properties: ->(*) { SECRET },
        identify: ->(*) { SECRET })
      tool_result(server, "echo", {msg: "hi"})
    end

    assert_includes log, "WARN: identify hook returned String, not an AgentCat::UserIdentity; the event has no identified user"
    assert_includes log, "WARN: event_properties hook returned String, not a Hash; ignored"
    assert_includes log, "WARN: redact_event hook returned String, not the event or nil; its result is ignored"
    refute_includes log, SECRET
  end

  def test_a_routine_tool_call_logs_nothing_at_warn
    server = build_server
    log = capture_log(level: Logger::WARN) do
      track(server, project_id: PROJECT_ID, event_tags: ->(*) { {"env" => "prod"} })
      tool_result(server, "echo", {msg: "hi"})
    end

    assert_empty log
  end
end
