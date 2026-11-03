# typed: true

require "digest"
require "securerandom"

module AgentCat
  module Exporters
    # Trace, span and UUIDv7 ids the exporters derive from AgentCat ids, byte for byte
    # the TS SDK's (src/modules/exporters/trace-context.ts and `toUUIDv7` in
    # src/modules/exporters/posthog.ts). The same session always lands in the same
    # trace, in every vendor and in every SDK language.
    module TraceContext
      KSUID_EPOCH = 1_400_000_000
      KSUID_BODY = /\A[0-9A-Za-z]{27}\z/
      BASE62 = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"

      class << self
        extend T::Sig

        # 32 hex digits: SHA-256 of the session id, or random when there is none.
        sig { params(session_id: T.nilable(String)).returns(String) }
        def trace_id(session_id)
          return SecureRandom.hex(16) if session_id.nil? || session_id.empty?

          T.must(Digest::SHA256.hexdigest(session_id)[0, 32])
        end

        # 16 hex digits: SHA-256 of the event id, or random when there is none.
        sig { params(event_id: T.nilable(String)).returns(String) }
        def span_id(event_id = nil)
          return SecureRandom.hex(8) if event_id.nil? || event_id.empty?

          T.must(Digest::SHA256.hexdigest(event_id)[0, 16])
        end

        # Datadog wants 64-bit decimal ids: the low half of the trace id.
        sig { params(session_id: T.nilable(String)).returns(String) }
        def datadog_trace_id(session_id)
          T.must(trace_id(session_id)[16, 16]).to_i(16).to_s
        end

        sig { params(event_id: T.nilable(String)).returns(String) }
        def datadog_span_id(event_id)
          span_id(event_id).to_i(16).to_s
        end

        # A deterministic UUIDv7 for a prefixed KSUID (ses_..., evt_...): the KSUID's
        # own time, then SHA-256 bits of the whole id. An id that is not a KSUID takes
        # its time from the hash too, so the same input always gives the same UUID.
        sig { params(prefixed_id: String).returns(String) }
        def uuid_v7(prefixed_id)
          hash = Digest::SHA256.digest(prefixed_id).bytes
          millis = ksuid_millis(prefixed_id.sub(/\A[a-z]+_/, "")) ||
            T.must(hash[10, 6]).inject(0) { |sum, byte| (sum << 8) | byte }

          bytes = [millis].pack("Q>").bytes.drop(2)
          bytes << (0x70 | (T.must(hash[0]) & 0x0f)) << T.must(hash[1])
          bytes << (0x80 | (T.must(hash[2]) & 0x3f))
          bytes.concat(T.must(hash[3, 7]))
          hex = bytes.pack("C*").unpack1("H*")
          [hex[0, 8], hex[8, 4], hex[12, 4], hex[16, 4], hex[20, 12]].join("-")
        end

        private

        # The KSUID's time in Unix milliseconds, or nil where TS's `KSUID.parse` throws.
        sig { params(body: String).returns(T.nilable(Integer)) }
        def ksuid_millis(body)
          return nil unless KSUID_BODY.match?(body)

          value = body.each_char.inject(0) { |sum, char| (sum * 62) + T.must(BASE62.index(char)) }
          return nil if value >= (1 << 160)

          ((value >> 128) + KSUID_EPOCH) * 1000
        end
      end
    end
  end
end
