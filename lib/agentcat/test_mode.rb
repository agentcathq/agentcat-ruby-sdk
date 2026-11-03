# typed: true

module AgentCat
  # When AgentCat instruments and delivers. `AgentCat.fake` decides first:
  # a fake always records. Then `AGENTCAT_ENABLED`: a false value turns AgentCat off
  # everywhere (an operator's kill switch), a true value turns it on everywhere, test
  # environments included. Otherwise AgentCat is off while a test framework runs and on
  # everywhere else, so a customer's test suite never sends events or diagnostics.
  module TestMode
    TRUE_WORDS = %w[true 1 yes on].freeze
    FALSE_WORDS = %w[false 0 no off].freeze
    TEST_ENV_NAMES = %w[RAILS_ENV RACK_ENV APP_ENV].freeze
    # By name: neither framework is a dependency of the gem.
    RUNNER_NAMES = %w[Minitest::Test RSpec::Core].freeze
    TEST_ENV_VALUES = %w[test testing].freeze

    @mutex = Mutex.new
    @reported = T.let(false, T::Boolean)

    class << self
      extend T::Sig

      # True when Minitest or RSpec is loaded, or RAILS_ENV / RACK_ENV / APP_ENV is
      # `test` or `testing` (trimmed, any case). `runner_loaded:` is a test seam.
      sig { params(runner_loaded: T::Boolean).returns(T::Boolean) }
      def test_environment?(runner_loaded: runner_loaded?)
        return true if runner_loaded

        TEST_ENV_NAMES.any? { |name| TEST_ENV_VALUES.include?(ENV[name].to_s.strip.downcase) }
      end

      # Whether `track` instruments and `publish_custom_event` publishes. An unknown
      # AGENTCAT_ENABLED value counts as unset and logs one WARN line per process.
      sig { params(runner_loaded: T::Boolean).returns(T::Boolean) }
      def sdk_enabled?(runner_loaded: runner_loaded?)
        return true if AgentCat.active_fake

        word = enabled_word
        return word unless word.nil?

        !test_environment?(runner_loaded: runner_loaded)
      end

      # The AGENTCAT_ENABLED word: true, false, or nil when unset, blank or unknown.
      sig { returns(T.nilable(T::Boolean)) }
      def enabled_word
        raw = ENV["AGENTCAT_ENABLED"].to_s
        value = raw.strip.downcase
        return true if TRUE_WORDS.include?(value)
        return false if FALSE_WORDS.include?(value)

        report_unknown(raw) unless value.empty?
        nil
      end

      # Tests only: forgets the logged line.
      sig { void }
      def reset!
        @mutex.synchronize { @reported = false }
      end

      private

      # A loaded runner, not an installed gem: `minitest` sits in many bundles as a
      # dependency, but only a test process loads Minitest::Test or RSpec::Core.
      sig { returns(T::Boolean) }
      def runner_loaded?
        RUNNER_NAMES.any? { |name| Object.const_defined?(name) }
      end

      sig { params(raw: String).void }
      def report_unknown(raw)
        first = @mutex.synchronize do
          next false if @reported

          @reported = true
        end
        return unless first

        AgentCat.logger.warn(
          "AGENTCAT_ENABLED #{raw.inspect} is not one of #{(TRUE_WORDS + FALSE_WORDS).join(", ")}; the default is used"
        )
      end
    end
  end
end
