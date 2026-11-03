require_relative "test_helper"
require "timeout"

class ForkSafetyTest < Minitest::Test
  def test_child_gets_a_working_queue_after_fork
    skip "fork not supported on this platform" unless Process.respond_to?(:fork)

    read, write = IO.pipe
    AgentCat.event_queue # make sure the queue exists and the fork hook is installed first

    pid = fork do
      read.close
      done = Queue.new
      AgentCat.event_queue.enqueue { done << :ok }
      ok = begin
        Timeout.timeout(2) { done.pop }
      rescue Timeout::Error
        nil
      end
      write.puts((ok == :ok) ? "ok" : "fail")
      write.close
      exit!(0)
    end
    write.close
    Process.wait(pid)

    assert_equal "ok", read.gets&.chomp
  ensure
    read&.close
    write&.close
  end
end
