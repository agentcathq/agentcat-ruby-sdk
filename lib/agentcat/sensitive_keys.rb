# typed: true

require_relative "payload_limits"

module AgentCat
  # Masks the values of sensitive keys (credential headers, tokens, secrets) in an event
  # field, at any depth. A port of the shared reference implementation; the shared
  # `test/fixtures/sensitive_keys_vectors.json` checks every port the same way.
  module SensitiveKeys
    extend T::Sig

    MASK = "[redacted]"

    # A key matches a name when its canonical form equals the name or ends with "-" + name.
    EXACT = [
      "accesskey", "cb-access-sign", "cf-access-client-id", "dpop", "fastly-key",
      "jenkins-crumb", "paypal-transmission-sig", "plaid-verification",
      "sec-websocket-protocol", "x-airtable-content-mac", "x-amzn-ava-user-context",
      "x-amzn-oidc-data", "x-firebase-appcheck", "x-forge-oauth-system",
      "x-forge-oauth-user", "x-honeycomb-team", "x-insert-key", "x-jfrog-art-api",
      "x-nf-sign", "x-registry-config", "x-requestdigest", "x-sfdc-session",
      "x-trello-webhook", "x-vault-mfa", "x-vercel-protection-bypass", "x-wp-nonce"
    ].freeze
    # A key matches when its canonical form contains the word.
    CONTAINS = [
      "authorization", "secret", "password", "passwd", "passphrase", "cookie", "signature",
      "credential", "jwt", "assertion", "bearer", "csrf", "xsrf", "hmac", "saml",
      "api-key", "apikey", "access-key", "private-key", "privatekey", "subscription-key",
      "encryption-key", "signing-key", "shared-key", "sharedkey", "master-key",
      "account-key", "app-key", "appkey", "application-key", "functions-key", "sas-key",
      "license-key", "consumer-key", "client-key", "customer-key"
    ].freeze
    # A key matches when one hyphen-separated part of its canonical form equals the word.
    SEGMENT = ["auth", "token", "otp"].freeze
    # A key matches when its canonical form ends with the word.
    SUFFIX = ["token"].freeze

    # The pair rule: a map that names a key in one entry and holds its value in another.
    PAIR_NAME_KEYS = ["name", "key", "header"].freeze
    PAIR_VALUE_KEYS = ["value", "values"].freeze
    # The children of a map stored under this exact key are JSON Schema property names.
    SCHEMA_PROPERTIES_KEY = "properties"

    sig { params(text: String).returns(String) }
    def self.camel_split(text)
      out = +""
      chars = text.chars
      chars.each_with_index do |ch, i|
        if i > 0 && ch.between?("A", "Z")
          prev = T.must(chars[i - 1])
          nxt = chars[i + 1] || ""
          if prev.between?("a", "z") || prev.between?("0", "9")
            out << "-"
          elsif prev.between?("A", "Z") && nxt.between?("a", "z")
            out << "-"
          end
        end
        out << ch
      end
      out
    end

    sig { params(text: String).returns(T::Array[String]) }
    def self.canonical_parts(text)
      out = +""
      text.each_char do |ch|
        out << if ch.between?("A", "Z")
          (ch.ord + 32).chr
        elsif ch.between?("a", "z") || ch.between?("0", "9")
          ch
        else
          "-"
        end
      end
      parts = out.split("-").reject(&:empty?)
      parts.pop while !parts.empty? && T.must(parts.last).each_char.all? { |c| c.between?("0", "9") }
      parts
    end

    sig { params(parts: T::Array[String]).returns(T::Boolean) }
    def self.parts_match(parts)
      return false if parts.empty?

      joined = parts.join("-")
      EXACT.each do |name|
        return true if joined == name || joined.end_with?("-" + name)
      end
      CONTAINS.each do |word|
        return true if joined.include?(word)
      end
      parts.each do |part|
        return true if SEGMENT.include?(part)
      end
      SUFFIX.each do |word|
        return true if joined.end_with?(word)
      end
      false
    end

    sig { params(key: String).returns(T::Boolean) }
    def self.is_sensitive_key(key)
      parts_match(canonical_parts(key)) || parts_match(canonical_parts(camel_split(key)))
    end

    sig { params(key: String).returns(String) }
    def self.canonical(key)
      canonical_parts(key).join("-")
    end

    sig { params(value: T.untyped, under_properties: T::Boolean, depth: Integer, seen: T::Set[Integer]).returns(T.untyped) }
    def self.mask_value(value, under_properties, depth, seen)
      return value if value.nil? || value == true || value == false
      return mask_sensitive_keys(value, false, depth, seen) if value.is_a?(Hash) && under_properties

      MASK
    end

    # A masked copy of `value`. `under_properties` is true when `value` is the map stored
    # under the key "properties". A Symbol key is tested by its name, as JSON writes it.
    # Depth and cycles are guarded like `Sanitization.sanitize_value`, but a stopped walk
    # becomes MASK.
    sig { params(value: T.untyped, under_properties: T::Boolean, depth: Integer, seen: T::Set[Integer]).returns(T.untyped) }
    def self.mask_sensitive_keys(value, under_properties = false, depth = 0, seen = Set.new)
      return value unless value.is_a?(Hash) || value.is_a?(Array)
      return MASK if depth >= PayloadLimits::MAX_WALK_DEPTH || !seen.add?(value.object_id)
      return value.map { |item| mask_sensitive_keys(item, false, depth + 1, seen) } if value.is_a?(Array)

      out = {}
      value.each do |key, child|
        name = key.is_a?(Symbol) ? key.to_s : key
        out[key] = if name.is_a?(String) && is_sensitive_key(name)
          mask_value(child, under_properties, depth + 1, seen)
        else
          mask_sensitive_keys(child, name == SCHEMA_PROPERTIES_KEY, depth + 1, seen)
        end
      end
      names_a_sensitive_key = T.let(false, T::Boolean)
      value.each do |key, child|
        name = key.is_a?(Symbol) ? key.to_s : key
        if name.is_a?(String) && PAIR_NAME_KEYS.include?(canonical(name))
          names_a_sensitive_key = true if child.is_a?(String) && is_sensitive_key(child)
        end
      end
      if names_a_sensitive_key
        value.each do |key, child|
          name = key.is_a?(Symbol) ? key.to_s : key
          out[key] = mask_value(child, false, depth + 1, seen) if name.is_a?(String) && PAIR_VALUE_KEYS.include?(canonical(name))
        end
      end
      out
    end
  end
end
