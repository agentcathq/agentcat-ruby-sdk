# typed: strict

require_relative "clock"

module AgentCat
  # Problem lines that can repeat once per event: a delivery that keeps failing, a full
  # queue, an exporter that is down, a hook that always raises, a tag the customer
  # always gets wrong. Each distinct line logs at most once per WINDOW seconds; the next
  # time it logs, it says how many repeats it held back. PHP collapses the same lines
  # per delivery (RepeatedLines); a Ruby server runs for days, so this uses a window.
  #
  # Levels: ERROR for lost events and exporter setup failures, WARN for hook
  # failures and customer data that AgentCat ignores. These lines name things (a tool,
  # an exporter class, an exception class), never payload values: details that can
  # carry them (an exception message) go to `AgentCat.logger.debug` at the call site.
  module Log
    extend T::Sig

    WINDOW = 60
    # Distinct lines remembered at once. Past it, the oldest is forgotten.
    MAX_LINES = 1000

    @mutex = T.let(Mutex.new, Mutex)
    # line => [monotonic time it last logged, repeats held back since]
    @lines = T.let({}, T::Hash[String, [Float, Integer]])

    class << self
      extend T::Sig

      sig { params(line: String).void }
      def error(line)
        write(:error, line)
      end

      sig { params(line: String).void }
      def warn(line)
        write(:warn, line)
      end

      # Forgets every line, for `AgentCat.reset!`.
      sig { void }
      def reset!
        @mutex.synchronize { @lines.clear }
      end

      private

      sig { params(level: Symbol, line: String).void }
      def write(level, line)
        held_back = admit(line)
        return if held_back.nil?

        text = held_back.zero? ? line : "#{line} (#{held_back} more since this was last logged)"
        logger = AgentCat.logger
        (level == :error) ? logger.error(text) : logger.warn(text)
      rescue
        # Logging must never cost the caller anything.
        nil
      end

      # nil when the line logged less than WINDOW seconds ago, else the repeats it held back.
      sig { params(line: String).returns(T.nilable(Integer)) }
      def admit(line)
        now = Clock.monotonic_now
        @mutex.synchronize do
          last = @lines[line]
          if last && now - last[0] < WINDOW
            @lines[line] = [last[0], last[1] + 1]
            return nil
          end

          @lines.delete(line)
          @lines.shift while @lines.size >= MAX_LINES
          @lines[line] = [now, 0]
          last ? last[1] : 0
        end
      end
    end
  end
end
