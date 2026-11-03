require_relative "test_helper"
require "timeout"

class EventQueueTest < Minitest::Test
  def test_processes_jobs_in_order
    queue = AgentCat::EventQueue.new
    ran = Queue.new

    5.times { |i| queue.enqueue { ran << i } }

    assert queue.flush(timeout: 1)
    assert_equal [0, 1, 2, 3, 4], Array.new(5) { ran.pop }
  end

  def test_drops_oldest_when_full
    queue = AgentCat::EventQueue.new(max_size: 3, worker_count: 1)
    gate = Queue.new
    started = Queue.new
    ran = Queue.new

    # occupy the one worker so nothing drains while we overfill the buffer
    queue.enqueue do
      started << :ready
      gate.pop
    end
    Timeout.timeout(1) { started.pop }

    5.times { |i| queue.enqueue { ran << i } }
    assert_equal 3, queue.size

    gate.push(:go)
    assert queue.flush(timeout: 1)
    assert_equal [2, 3, 4], Array.new(3) { ran.pop }.sort
  end

  def test_a_raising_job_does_not_kill_the_worker
    queue = AgentCat::EventQueue.new
    done = Queue.new

    queue.enqueue { raise "boom" }
    queue.enqueue { done << :ok }

    assert_equal :ok, Timeout.timeout(1) { done.pop }
  end

  def test_flush_times_out_while_a_job_is_still_running
    queue = AgentCat::EventQueue.new
    gate = Queue.new
    started = Queue.new

    queue.enqueue do
      started << :ready
      gate.pop
    end
    Timeout.timeout(1) { started.pop }

    refute queue.flush(timeout: 0.05)

    gate.push(:go)
    assert queue.flush(timeout: 1)
  end

  # Without this check, `enqueue` would spawn a worker that sees `@stopped` already
  # true and dies immediately - the job sits buffered forever with nothing left to
  # drain it, and `flush` would hang until its timeout instead of returning quickly.
  def test_enqueue_after_shutdown_is_a_no_op
    queue = AgentCat::EventQueue.new
    done = Queue.new

    queue.enqueue { done << :first }
    Timeout.timeout(1) { done.pop }

    queue.shutdown
    queue.enqueue { done << :second }

    assert_equal 0, queue.size
    assert queue.flush(timeout: 0.2)
    assert_empty done
  end

  def test_reset_after_fork_clears_pending_work
    # worker_count: 0 so nothing drains the buffer while we inspect it
    queue = AgentCat::EventQueue.new(worker_count: 0)
    queue.enqueue {}
    queue.enqueue {}
    assert_equal 2, queue.size

    queue.reset_after_fork!

    assert_equal 0, queue.size
  end
end
