# typed: true

module AgentCat
  # Mints "evt_<KSUID>" ids, same scheme as session ids ("ses_"). The events API
  # will happily 202 a request with no id and then silently drop it server-side,
  # so don't skip this.
  class EventId
    PREFIX = "evt_"

    class << self
      extend T::Sig

      sig { returns(String).checked(:tests) }
      def mint
        SessionManager.mint_id(T.must(PREFIX))
      end
    end
  end
end
