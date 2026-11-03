# typed: true

module AgentCat
  # Monotonic clock for measuring elapsed time. Don't use Time.now for this; NTP can
  # step it backwards mid-call. Interceptor and EventQueue both depend on it.
  module Clock
    class << self
      extend T::Sig

      sig { returns(Float) }
      def monotonic_now
        Process.clock_gettime(Process::CLOCK_MONOTONIC).to_f
      end
    end
  end
end
