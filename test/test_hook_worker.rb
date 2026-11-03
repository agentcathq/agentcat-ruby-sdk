require_relative "test_helper"

# `Hooks::Worker` is `Hooks.run` for hooks called once per value - one thread for the
# whole pass, a timeout on every call.
class HookWorkerTest < Minitest::Test
  include AgentCatTestHelpers

  def test_returns_the_hooks_value
    worker = AgentCat::Hooks::Worker.new(->(text) { text.upcase }, timeout: 1)

    assert_equal "HELLO", worker.call("hello")
    assert_equal "WORLD", worker.call("world")
  ensure
    worker&.close
  end

  def test_every_call_runs_on_the_same_thread
    threads = []
    worker = AgentCat::Hooks::Worker.new(->(text) {
      threads << Thread.current
      text
    }, timeout: 1)

    5.times { |i| worker.call("value #{i}") }

    assert_equal 5, threads.size
    assert_equal 1, threads.uniq.size
    refute_equal Thread.current, threads.first
  ensure
    worker&.close
  end

  def test_a_raising_call_returns_nil_and_the_next_one_still_works
    worker = AgentCat::Hooks::Worker.new(->(text) {
      raise "boom" if text == "bad"
      text
    }, timeout: 1)

    assert_nil worker.call("bad")
    assert_equal "good", worker.call("good")
  ensure
    worker&.close
  end

  def test_a_timed_out_call_returns_nil_and_never_finishes_in_the_background
    finished = []
    worker = AgentCat::Hooks::Worker.new(->(text) {
      sleep 0.3 if text == "slow"
      finished << text
      text
    }, timeout: 0.05)

    started = AgentCat::Clock.monotonic_now
    assert_nil worker.call("slow")
    assert_operator AgentCat::Clock.monotonic_now - started, :<, 0.25

    # A fresh thread picks up the next call; the killed one is gone for good.
    assert_equal "fast", worker.call("fast")
    sleep 0.4
    assert_equal ["fast"], finished
  ensure
    worker&.close
  end

  # NotImplementedError is a ScriptError, not a StandardError - it kills the thread
  # instead of being handed back, so the call waits out the timeout.
  def test_a_non_standard_error_costs_the_timeout_then_recovers
    worker = AgentCat::Hooks::Worker.new(->(text) {
      raise NotImplementedError if text == "bad"
      text
    }, timeout: 0.05)

    assert_nil worker.call("bad")
    assert_equal "good", worker.call("good")
  ensure
    worker&.close
  end

  def test_close_lets_the_thread_exit
    thread = nil
    worker = AgentCat::Hooks::Worker.new(->(text) {
      thread = Thread.current
      text
    }, timeout: 1)
    worker.call("hello")

    worker.close

    assert thread.join(1), "worker thread should exit after close"
  end

  # The point of the worker: a big event costs one thread, not one per string.
  def test_sensitive_redaction_uses_one_thread_for_the_whole_event
    server = build_server
    threads = []
    redact = ->(text) {
      threads << Thread.current
      text.gsub("secret", "[REDACTED]")
    }
    client = track(server, project_id: PROJECT_ID, redact_sensitive_information: redact)

    tool_result(server, "echo", {msg: "my secret"})

    assert_operator threads.size, :>, 1
    assert_equal 1, threads.uniq.size
    assert_equal "my [REDACTED]", client.last_event[:parameters]["arguments"]["msg"]
    assert threads.first.join(1), "worker thread should be gone once the event is done"
  end
end
