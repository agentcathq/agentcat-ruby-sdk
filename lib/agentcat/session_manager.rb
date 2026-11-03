# typed: true

require "digest"
require "securerandom"

module AgentCat
  # Mints/validates "ses_<27-char base62 KSUID>" ids, same format the backend uses.
  # No signature needed — 128 random bits already make these unguessable.
  class SessionManager
    PREFIX = "ses_"
    START_SENTINEL = "start"
    KSUID_EPOCH = 1_400_000_000 # 2017-05-13T16:53:20Z, the standard KSUID epoch (seconds)
    # 2024-01-01T00:00:00Z in Unix milliseconds — the fixed epoch used for
    # deterministic (derived) session IDs, matching the Go/TypeScript SDKs.
    EPOCH_2024_MS = 1_704_067_200_000
    # Caps the deterministic timestamp offset at one year (same as the Go SDK).
    MAX_TIMESTAMP_OFFSET_MS = 365 * 24 * 60 * 60 * 1000
    BASE62_ALPHABET = "0123456789ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz"
    BODY_PATTERN = /\A[0-9A-Za-z]{27}\z/

    class << self
      extend T::Sig

      sig { returns(String).checked(:tests) }
      def mint_session_id
        mint_id(T.must(PREFIX))
      end

      # Shared by SessionManager (ses_) and EventId (evt_) — same KSUID body, different prefix.
      sig { params(prefix: String).returns(String) }
      def mint_id(prefix)
        "#{prefix}#{generate_ksuid}"
      end

      sig { params(session_id: T.untyped).returns(T::Boolean).checked(:tests) }
      def valid?(session_id)
        return false unless session_id.is_a?(String)

        session_id.start_with?(PREFIX) && BODY_PATTERN.match?(session_id.delete_prefix(PREFIX))
      end

      # Deterministically turns a host's own correlation id into a session id. Same
      # input always produces the same output, across processes and restarts, so
      # workers never split a session. Has to match the Go SDK's DeriveSessionID
      # byte-for-byte — if you touch this, check against the golden vectors.
      sig { params(customer_id: T.nilable(String), project_id: T.nilable(String)).returns(String) }
      def derive_session_id(customer_id, project_id = nil)
        input = project_id.to_s.empty? ? customer_id.to_s : "#{customer_id}:#{project_id}"
        hash = Digest::SHA256.digest(input)
        offset_ms = hash.byteslice(0, 4).unpack1("N") % MAX_TIMESTAMP_OFFSET_MS
        timestamp_seconds = (EPOCH_2024_MS + offset_ms) / 1000
        ksuid_seconds = timestamp_seconds - KSUID_EPOCH
        raw = [ksuid_seconds].pack("N") + hash.byteslice(4, 16)
        "#{PREFIX}#{base62_encode(raw)}"
      end

      sig { params(value: T.untyped).returns(T::Boolean).checked(:tests) }
      def start_sentinel?(value)
        value.is_a?(String) && value.strip.casecmp?(START_SENTINEL)
      end

      private

      sig { returns(String) }
      def generate_ksuid
        timestamp = Time.now.to_i - KSUID_EPOCH
        raw = [timestamp].pack("N") + SecureRandom.random_bytes(16)
        base62_encode(raw)
      end

      sig { params(bytes: String).returns(String) }
      def base62_encode(bytes)
        number = bytes.unpack1("H*").to_i(16)
        chars = T.let([], T::Array[String])
        while number.positive?
          number, remainder = number.divmod(62)
          chars.unshift(T.must(BASE62_ALPHABET[remainder]))
        end
        chars.join.rjust(27, "0")
      end
    end
  end
end
