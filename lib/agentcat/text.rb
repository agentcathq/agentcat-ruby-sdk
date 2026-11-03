# typed: strict

module AgentCat
  # String helpers that count the way the TypeScript SDK does. Every string length limit
  # (field caps, the 32K normalize cap, tag keys and values) is in UTF-16 code units, the
  # unit of JavaScript's `String#length`, so a limit means the same thing in every SDK.
  module Text
    extend T::Sig

    REPLACEMENT = "\uFFFD"

    # Valid UTF-8 for any string, so JSON encoding can never fail on it. Binary
    # (ASCII-8BIT) strings are read as UTF-8 bytes; every invalid byte becomes U+FFFD,
    # like the PHP SDK. Other encodings are converted. Valid UTF-8 comes back as is.
    sig { params(value: String).returns(String) }
    def self.scrub(value)
      return value if value.encoding == Encoding::UTF_8 && value.valid_encoding?

      utf8 = if [Encoding::BINARY, Encoding::US_ASCII, Encoding::UTF_8].include?(value.encoding)
        value.dup.force_encoding(Encoding::UTF_8)
      else
        begin
          value.encode(Encoding::UTF_8, invalid: :replace, undef: :replace, replace: REPLACEMENT)
        rescue EncodingError
          value.dup.force_encoding(Encoding::UTF_8)
        end
      end
      utf8.scrub(REPLACEMENT)
    end

    # Length in UTF-16 code units: one per code point, two for code points above U+FFFF.
    sig { params(value: String).returns(Integer) }
    def self.utf16_length(value)
      value = scrub(value)
      return value.bytesize if value.ascii_only?

      value.length + value.each_codepoint.count { |code| code > 0xFFFF }
    end

    # True when `value` is longer than `max` UTF-16 code units. A string never has more
    # UTF-16 code units (after scrubbing) than bytes, so the byte size rules most strings
    # out cheaply.
    sig { params(value: String, max: Integer).returns(T::Boolean) }
    def self.exceeds_utf16?(value, max)
      value.bytesize > max && utf16_length(value) > max
    end

    # The first `max` UTF-16 code units. A character that would be split in half at the
    # cut (a surrogate pair) is dropped whole, like the PHP SDK, so the result is always
    # valid UTF-8 and can be JSON encoded.
    sig { params(value: String, max: Integer).returns(String) }
    def self.utf16_slice(value, max)
      value = scrub(value)
      return T.must(value[0, max]) if value.ascii_only?

      units = 0
      chars = 0
      value.each_codepoint do |code|
        width = (code > 0xFFFF) ? 2 : 1
        break if units + width > max

        units += width
        chars += 1
      end
      T.must(value[0, chars])
    end
  end
end
