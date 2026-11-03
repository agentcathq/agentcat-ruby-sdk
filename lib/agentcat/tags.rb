# typed: true

require_relative "payload_limits"
require_relative "text"

module AgentCat
  # Validates `event_tags` hook output and `publish_custom_event`'s `tags:` the same
  # way: matches agentcat-api's generated limits (keys up to 32 chars from a fixed
  # charset, values up to 200 with no newlines, 50 entries max). Lengths are UTF-16
  # code units, like the TS SDK. Bad entries are dropped one at a time, not the whole hash.
  # Dropping anything logs one WARN line (rate-limited) with the count, never the tags.
  module Tags
    extend T::Sig

    # `source` names where the tags came from, for the WARN line.
    sig { params(value: T.untyped, source: String).returns(T::Hash[String, String]) }
    def self.sanitize(value, source = "tags")
      return {} if value.nil?

      unless value.is_a?(Hash)
        Log.warn("#{source}: expected a Hash of tags, got #{value.class}; ignored")
        return {}
      end

      invalid = 0
      over_limit = 0
      kept = value.each_with_object({}) do |(key, val), acc|
        if !valid_key?(key) || !valid_value?(val)
          invalid += 1
        elsif acc.size >= PayloadLimits::MAX_TAGS
          over_limit += 1
        else
          acc[key] = val
        end
      end
      warn_dropped(source, invalid, over_limit)
      kept
    end

    sig { params(source: String, invalid: Integer, over_limit: Integer).void }
    def self.warn_dropped(source, invalid, over_limit)
      reasons = []
      reasons << "#{invalid} invalid (a key is a String of up to #{PayloadLimits::MAX_TAG_KEY_LENGTH} letters, digits, spaces or _.:$-; a value is a String of up to #{PayloadLimits::MAX_TAG_VALUE_LENGTH} characters with no line break)" if invalid.positive?
      reasons << "#{over_limit} over the limit of #{PayloadLimits::MAX_TAGS} tags" if over_limit.positive?
      Log.warn("#{source}: dropped #{reasons.join(" and ")}") unless reasons.empty?
    end
    private_class_method :warn_dropped

    sig { params(key: T.untyped).returns(T::Boolean) }
    def self.valid_key?(key)
      !!(key.is_a?(String) && !Text.exceeds_utf16?(key, PayloadLimits::MAX_TAG_KEY_LENGTH) && PayloadLimits::TAG_KEY_PATTERN.match?(key))
    end
    private_class_method :valid_key?

    sig { params(value: T.untyped).returns(T::Boolean) }
    def self.valid_value?(value)
      !!(value.is_a?(String) && !Text.exceeds_utf16?(value, PayloadLimits::MAX_TAG_VALUE_LENGTH) && !value.match?(/[\r\n]/))
    end
    private_class_method :valid_value?
  end
end
