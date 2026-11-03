require_relative "test_helper"
require "minitest/mock"

class LogTest < Minitest::Test
  include AgentCatTestHelpers

  def test_a_repeated_line_logs_once_per_window_then_counts_what_it_held_back
    now = 1000.0
    log = AgentCat::Clock.stub(:monotonic_now, -> { now }) do
      capture_log do
        3.times { AgentCat::Log.error("exporter Foo failed") }
        AgentCat::Log.warn("another line")
        now += AgentCat::Log::WINDOW - 1
        AgentCat::Log.error("exporter Foo failed")
        now += 2
        AgentCat::Log.error("exporter Foo failed")
        AgentCat::Log.error("exporter Foo failed")
      end
    end

    assert_equal [
      "ERROR: exporter Foo failed",
      "WARN: another line",
      "ERROR: exporter Foo failed (3 more since this was last logged)"
    ], log.lines(chomp: true)
  end

  def test_reset_forgets_the_lines
    log = capture_log do
      AgentCat::Log.warn("once")
      AgentCat.reset!
      AgentCat::Log.warn("once")
    end

    assert_equal ["WARN: once", "WARN: once"], log.lines(chomp: true)
  end

  def test_it_remembers_a_bounded_number_of_lines
    capture_log { (AgentCat::Log::MAX_LINES + 50).times { |i| AgentCat::Log.warn("line #{i}") } }

    assert_equal AgentCat::Log::MAX_LINES, AgentCat::Log.instance_variable_get(:@lines).size
  end

  def test_a_broken_logger_does_not_raise
    broken = Object.new
    def broken.error(*) = raise(IOError, "closed")
    AgentCat.stub(:logger, broken) { AgentCat::Log.error("x") }
  end
end
