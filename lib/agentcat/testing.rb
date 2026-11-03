# typed: true

module AgentCat
  # Test doubles for your own test suite. Loaded on first use of `AgentCat.fake` (or
  # `require "agentcat/testing"`), never by `require "agentcat"` alone.
  module Testing
    # Raised by a failed `Fake` assertion when neither Minitest nor RSpec is loaded.
    class AssertionError < StandardError; end

    # What `AgentCat.fake` returns. While it is active, every
    # event is recorded here - after hooks, redaction, sanitization and truncation -
    # and nothing goes to AgentCat, to the exporters, or to diagnostics. It records
    # whatever AGENTCAT_ENABLED says, so a CI that sets AGENTCAT_ENABLED=false still
    # works. `AgentCat.reset!` (in your teardown) removes it.
    #
    # Events are the wire hashes AgentCat would send (`event[:event_type]`,
    # `event[:resource_name]`, `event[:parameters]`, ...). Assertions raise
    # Minitest::Assertion under Minitest, RSpec::Expectations::ExpectationNotMetError
    # under RSpec, and AgentCat::Testing::AssertionError otherwise.
    class Fake
      extend T::Sig

      TOOL_CALL = "mcp:tools/call"
      CUSTOM_EVENT = "agentcat:custom"
      FLUSH_TIMEOUT = 5

      sig { void }
      def initialize
        @mutex = T.let(Mutex.new, Mutex)
        @events = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
      end

      # Every recorded event, in publish order. Waits for queued events first, so a
      # tool call that just returned is in the list.
      sig { returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def events
        AgentCat.flush(timeout: FLUSH_TIMEOUT)
        @mutex.synchronize { @events.dup }
      end

      # Called by AgentCat's pipeline; not part of the API.
      sig { params(event: T::Hash[Symbol, T.untyped]).void }
      def record(event)
        @mutex.synchronize { @events << event }
      end

      # Asserts that a tool call (`mcp:tools/call`) was tracked: of `tool_name` when
      # given, matching the block when given, and exactly `count:` of them when given
      # (else at least one).
      sig do
        params(
          tool_name: T.nilable(String),
          count: T.nilable(Integer),
          filter: T.nilable(T.proc.params(event: T::Hash[Symbol, T.untyped]).returns(T.untyped))
        ).void
      end
      def assert_tracked(tool_name = nil, count: nil, &filter)
        tool_calls = of_type(TOOL_CALL)
        matched = matching(tool_calls, tool_name, filter)
        what = describe("a tool call", tool_name, filter)
        if count.nil?
          check(!matched.empty?, hinted("Expected #{what} to be tracked, but none was. Tracked: #{names(tool_calls)}.", tool_calls))
        else
          check(matched.size == count, hinted("Expected #{count} of #{what} to be tracked, got #{matched.size}. Tracked: #{names(tool_calls)}.", tool_calls))
        end
      end

      # Asserts the number of tracked tool calls; custom events do not count.
      sig { params(count: Integer).void }
      def assert_tracked_count(count)
        tool_calls = of_type(TOOL_CALL)
        check(tool_calls.size == count, hinted("Expected #{count} tool call(s) to be tracked, got #{tool_calls.size}. Tracked: #{names(tool_calls)}.", tool_calls))
      end

      # Asserts that no event of any type was recorded.
      sig { void }
      def assert_nothing_tracked
        recorded = events
        check(recorded.empty?, "Expected nothing to be tracked, but #{recorded.size} event(s) were: #{names(recorded)}.")
      end

      # Asserts that a custom event (`agentcat:custom`) was published: with
      # `resource_name` when given, and matching the block when given.
      sig do
        params(
          resource_name: T.nilable(String),
          filter: T.nilable(T.proc.params(event: T::Hash[Symbol, T.untyped]).returns(T.untyped))
        ).void
      end
      def assert_custom_event_published(resource_name = nil, &filter)
        custom = of_type(CUSTOM_EVENT)
        what = describe("a custom event", resource_name, filter)
        check(!matching(custom, resource_name, filter).empty?, "Expected #{what} to be published, but none was. Published: #{names(custom)}.")
      end

      private

      sig { params(event_type: String).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def of_type(event_type)
        events.select { |event| event[:event_type] == event_type }
      end

      sig do
        params(
          events: T::Array[T::Hash[Symbol, T.untyped]],
          name: T.nilable(String),
          filter: T.nilable(T.proc.params(event: T::Hash[Symbol, T.untyped]).returns(T.untyped))
        ).returns(T::Array[T::Hash[Symbol, T.untyped]])
      end
      def matching(events, name, filter)
        events.select { |event| (name.nil? || event[:resource_name] == name) && (filter.nil? || filter.call(event)) }
      end

      sig { params(kind: String, name: T.nilable(String), filter: T.untyped).returns(String) }
      def describe(kind, name, filter)
        text = name ? "#{kind} named #{name.inspect}" : kind
        filter ? "#{text} matching the block" : text
      end

      sig { params(events: T::Array[T::Hash[Symbol, T.untyped]]).returns(String) }
      def names(events)
        return "none" if events.empty?

        events.map { |event| event[:resource_name].inspect }.join(", ")
      end

      # Says why nothing may have been recorded: a server tracked while AgentCat was
      # off is not tracked at all.
      sig { params(message: String, tool_calls: T::Array[T.untyped]).returns(String) }
      def hinted(message, tool_calls)
        return message unless tool_calls.empty? && AgentCat.skipped_track?

        "#{message} A server was tracked while AgentCat was off: call AgentCat.fake before AgentCat.track."
      end

      sig { params(condition: T::Boolean, message: String).void }
      def check(condition, message)
        return if condition

        raise failure_class, message
      end

      # Looked up by name: neither framework is a dependency of the gem.
      FAILURE_CLASS_NAMES = %w[Minitest::Assertion RSpec::Expectations::ExpectationNotMetError].freeze

      sig { returns(T.class_of(Exception)) }
      def failure_class
        name = FAILURE_CLASS_NAMES.find { |candidate| Object.const_defined?(candidate) }
        name ? Object.const_get(name) : AssertionError
      end
    end
  end
end
