# typed: strict

module AgentCat
  # Bounded, drop-oldest job queue with a small lazily-spawned worker pool. Plain Array
  # + Mutex instead of SizedQueue on purpose: SizedQueue blocks the caller once full,
  # and we'd rather drop the oldest job than stall whoever's enqueueing.
  class EventQueue
    extend T::Sig

    DEFAULT_MAX_SIZE = 10_000
    DEFAULT_WORKER_COUNT = 1

    sig { params(max_size: Integer, worker_count: Integer).void }
    def initialize(max_size: DEFAULT_MAX_SIZE, worker_count: DEFAULT_WORKER_COUNT)
      @max_size = max_size
      @worker_count = worker_count
      @mutex = T.let(Mutex.new, Mutex)
      @not_empty = T.let(ConditionVariable.new, ConditionVariable)
      @buffer = T.let([], T::Array[T.proc.void])
      @workers = T.let([], T::Array[Thread])
      @in_flight = T.let(0, Integer)
      @stopped = T.let(false, T::Boolean)
      @pid = T.let(Process.pid, Integer)
    end

    # Used by AgentCat.reset! so a stale queue can't deliver into post-reset state.
    # A job already in flight keeps running — Delivery checks the reset epoch itself.
    sig { void }
    def shutdown
      @mutex.synchronize do
        @stopped = true
        @buffer.clear
        @not_empty.broadcast
        @workers = []
      end
    end

    # Runs `job` on a worker thread later. Never raises into the caller. A no-op after
    # `shutdown` - without this check, a worker spawned here would see `@stopped` already
    # true and exit immediately, leaving the job buffered forever with nothing left alive
    # to drain it.
    sig { params(job: T.proc.void).void }
    def enqueue(&job)
      return if stopped?

      spawn_workers_if_needed
      dropped = @mutex.synchronize do
        return if @stopped

        count = 0
        while @buffer.size >= @max_size
          @buffer.shift
          count += 1
        end
        @buffer.push(job)
        @not_empty.signal
        count
      end
      Log.error("event queue is full (#{@max_size} events); dropped the oldest event") if dropped.positive?
    end

    sig { returns(Integer) }
    def size
      @mutex.synchronize { @buffer.size }
    end

    # Waits up to `timeout` seconds for the queue to drain. Returns whether it did.
    sig { params(timeout: Numeric).returns(T::Boolean) }
    def flush(timeout: 5)
      deadline = Clock.monotonic_now + timeout.to_f
      loop do
        return true if idle?
        return false if Clock.monotonic_now >= deadline

        sleep 0.01
      end
    end

    # A forked child doesn't inherit the parent's worker threads, so anything queued
    # would just sit there. Called from the Process._fork hook — see ForkSafety.
    sig { void }
    def reset_after_fork!
      @mutex.synchronize do
        @buffer = []
        @workers = []
        @in_flight = 0
        @stopped = false
        @pid = Process.pid
      end
    end

    private

    sig { returns(T::Boolean) }
    def idle?
      @mutex.synchronize { @buffer.empty? && @in_flight.zero? }
    end

    sig { void }
    def spawn_workers_if_needed
      reset_after_fork! if @pid != Process.pid
      return if workers_alive?

      @mutex.synchronize do
        next if workers_alive?

        @workers = Array.new(@worker_count) { spawn_worker }
      end
    end

    sig { returns(T::Boolean) }
    def workers_alive?
      @workers.any? { |worker| worker.alive? }
    end

    sig { returns(Thread) }
    def spawn_worker
      Thread.new do
        until stopped?
          job = take_job
          next unless job

          begin
            job.call
          rescue => e
            Log.error("queued event job raised #{e.class}; its event is lost")
            AgentCat.logger.debug { "queued job raised: #{e.class}: #{e.message}" }
          ensure
            @mutex.synchronize { @in_flight -= 1 }
          end
        end
      end
    end

    sig { returns(T.nilable(T.proc.void)) }
    def take_job
      @mutex.synchronize do
        @not_empty.wait(@mutex) while @buffer.empty? && !@stopped
        return nil if @stopped

        @in_flight += 1
        @buffer.shift
      end
    end

    sig { returns(T::Boolean) }
    def stopped?
      @mutex.synchronize { @stopped }
    end
  end
end
