# typed: true

module AgentCat
  # Puma cluster mode, Unicorn, Passenger, Spring — they all fork, and the event queue's
  # worker threads don't survive it. Without this a forked child just piles up events
  # nobody's draining. Hooks Process._fork (3.1+) instead of monkey-patching Kernel#fork.
  module ForkSafety
    extend T::Sig

    module Patch
      def _fork
        pid = super
        AgentCat.reset_event_queue_after_fork! if pid == 0
        pid
      end
    end

    class << self
      extend T::Sig

      sig { void }
      def install!
        return if @installed

        @installed = true
        Process.singleton_class.prepend(Patch)
      end
    end
  end
end
