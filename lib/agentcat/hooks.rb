# typed: true

require_relative "clock"
require_relative "log"

module AgentCat
  # Runs a user-supplied hook with a timeout, isolated from the call it's attached to.
  # A hook that misbehaves (raises, times out, returns garbage) just loses that one
  # event's data — it never takes the tool call down with it.
  module Hooks
    class << self
      extend T::Sig

      # Returns the hook's value, or nil if it's absent, raises, times out, or isn't callable.
      # A failure logs one WARN line (rate-limited, see `Log`) naming the hook option and
      # the exception class; the exception message, which can carry the hook's input, goes
      # to debug.
      sig { params(hook: T.untyped, args: T.untyped, timeout: Numeric, name: String).returns(T.untyped).checked(:tests) }
      def run(hook, *args, timeout: 1, name: "hook")
        return nil unless hook

        validate_callable!(hook)

        thread = Thread.new { hook.call(*args) }
        thread.report_on_exception = false
        thread.join(timeout)

        if thread.alive?
          thread.kill
          Log.warn("#{name} hook timed out after #{timeout}s")
          return nil
        end

        thread.value
      rescue => e
        Log.warn("#{name} hook raised #{e.class}")
        AgentCat.logger.debug { "#{name} hook raised #{e.class}: #{e.message}" }
        nil
      end

      # Hooks that see a call (`identify`, `resolve_session_id`, `event_tags`,
      # `event_properties`) take one `AgentCat::ToolCall`. A hook that still
      # needs two arguments (the old `(arguments, server_context)`) gets one WARN line
      # naming the new form. It is still called with the ToolCall: a lambda then raises
      # ArgumentError, which costs the hook's value for that call, never the call.
      sig { params(hook: T.untyped, name: String).void }
      def warn_if_two_arguments(hook, name)
        return if hook.nil?

        callable = (hook.is_a?(Proc) || hook.is_a?(Method)) ? hook : hook.method(:call)
        arity = callable.arity
        return unless arity >= 2 || arity <= -3

        Log.warn("#{name} takes 2 arguments, but hooks now get one AgentCat::ToolCall: " \
                 "change ->(arguments, server_context) { ... } to ->(tool_call) { ... } " \
                 "and read tool_call.arguments and tool_call.server_context")
      rescue
        nil
      end

      private

      sig { params(hook: T.untyped).void }
      def validate_callable!(hook)
        return if hook.respond_to?(:call)

        raise ArgumentError, "hook must respond to #call, got #{hook.class}"
      end
    end

    # `Hooks.run` for a hook called once per value (redact_sensitive_information on
    # every string of an event): one thread for the whole pass instead of one per call,
    # which on a big response cost far more than the hook itself. Each call still gets
    # its own timeout; a call that runs past it kills the thread and the next call
    # starts a fresh one. `close` when done. Failures log at debug only: the caller
    # (Redaction) logs the WARN line, once for the event it drops.
    class Worker
      extend T::Sig

      sig { params(hook: T.untyped, timeout: Numeric).void }
      def initialize(hook, timeout:)
        @hook = hook
        @timeout = timeout
        @inbox = T.let(nil, T.nilable(Thread::Queue))
        @thread = T.let(nil, T.nilable(Thread))
      end

      # Same contract as `Hooks.run`: the hook's value, or nil if it raised or timed out.
      sig { params(args: T.untyped).returns(T.untyped) }
      def call(*args)
        start unless @thread&.alive?
        slot = Slot.new
        T.must(@inbox) << [args, slot]

        unless slot.wait(@timeout)
          stop
          AgentCat.logger.debug { "hook timed out after #{@timeout}s" }
          return nil
        end

        error = slot.error
        return slot.value unless error

        AgentCat.logger.debug { "hook raised #{error.class}: #{error.message}" }
        nil
      end

      sig { void }
      def close
        @inbox&.close
        @inbox = nil
        @thread = nil
      end

      private

      sig { void }
      def start
        inbox = @inbox = Thread::Queue.new
        hook = @hook
        @thread = Thread.new do
          while (job = inbox.pop)
            args, slot = job
            begin
              slot.fulfill(value: hook.call(*args))
            # Anything worse than a StandardError takes the thread down with it; the
            # caller then just waits out the timeout, same as a hung call.
            rescue => e
              slot.fulfill(error: e)
            end
          end
        end
        T.must(@thread).report_on_exception = false
      end

      sig { void }
      def stop
        @thread&.kill
        @inbox&.close
        @inbox = nil
        @thread = nil
      end

      # One call's result, handed from the worker thread back to the caller.
      class Slot
        extend T::Sig

        sig { returns(T.untyped) }
        attr_reader :value

        sig { returns(T.nilable(Exception)) }
        attr_reader :error

        sig { void }
        def initialize
          @mutex = Mutex.new
          @done_signal = ConditionVariable.new
          @done = T.let(false, T::Boolean)
          @value = T.let(nil, T.untyped)
          @error = T.let(nil, T.nilable(Exception))
        end

        sig { params(value: T.untyped, error: T.nilable(Exception)).void }
        def fulfill(value: nil, error: nil)
          @mutex.synchronize do
            @value = value
            @error = error
            @done = true
            @done_signal.signal
          end
        end

        # false when `timeout` ran out first.
        sig { params(timeout: Numeric).returns(T::Boolean) }
        def wait(timeout)
          deadline = Clock.monotonic_now + timeout
          @mutex.synchronize do
            until @done
              remaining = deadline - Clock.monotonic_now
              return false if remaining <= 0

              @done_signal.wait(@mutex, remaining)
            end
          end
          true
        end
      end
    end
  end
end
