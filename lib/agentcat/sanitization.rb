# typed: true

require_relative "payload_limits"
require_relative "text"

module AgentCat
  # Runs between the redaction hooks and truncation — same pipeline order as
  # Go/Python/TS: redact_event -> per-string redact -> sanitize -> truncate -> deliver.
  #
  # Two things happen here, mirroring the Go SDK's internal/sanitization:
  #   1. Content types AgentCat can't store (image, audio, binary resources) get
  #      swapped for explanatory text blocks.
  #   2. Strings that look like base64 and are big enough to be an inline binary
  #      payload get replaced with a redaction marker. The scan is depth-capped
  #      and circular-safe so hostile input can't blow the stack.
  #
  # `scrub_event` is separate: it makes every string valid UTF-8 so JSON encoding can't
  # fail. `EventPipeline` runs it before the redaction hooks and again before encoding.
  #
  # Mutates the event in place, never raises — a failure here just means the event
  # ships unsanitized rather than not at all, same as Go/Python.
  module Sanitization
    extend T::Sig

    IMAGE_REDACTED = "[image content redacted - not supported by AgentCat]"
    AUDIO_REDACTED = "[audio content redacted - not supported by AgentCat]"
    BINARY_RESOURCE_REDACTED = "[binary resource content redacted - not supported by AgentCat]"
    BINARY_DATA_REDACTED = "[binary data redacted - not supported by AgentCat]"
    UNSUPPORTED_TYPE_PATTERN = "[unsupported content type \"%s\" redacted - not supported by AgentCat]"

    # Mirrors the Go/TS regex. Anchored, so it only matches a whole base64 payload.
    BASE64_PATTERN = %r{\A[A-Za-z0-9+/\n\r]+=*\z}

    sig { params(event: UnredactedEvent).void }
    def self.sanitize_event(event)
      event.response = sanitize_response(event.response) unless event.response.nil?
      event.parameters = sanitize_value(event.parameters)
      event.identify_data = sanitize_value(event.identify_data) if event.identify_data.is_a?(Hash)
      event.error = sanitize_value(event.error) if event.error.is_a?(Hash)
      event.properties = sanitize_value(event.properties) if event.properties.is_a?(Hash)
    end

    # Every string on the event (top-level fields, hash keys and values at any depth,
    # tags, properties) becomes valid UTF-8: binary and malformed bytes turn into U+FFFD,
    # so no string can make JSON encoding fail and lose the event. Containers are copied,
    # never changed in place, so the caller's own objects stay as they were.
    sig { params(event: UnredactedEvent).void }
    def self.scrub_event(event)
      UnredactedEvent.props.each_key do |name|
        value = event.public_send(name)
        next unless value.is_a?(String) || value.is_a?(Hash) || value.is_a?(Array)

        event.public_send(:"#{name}=", scrub_value(value))
      end
    rescue => e
      AgentCat.logger.debug { "UTF-8 scrub failed: #{e.class}: #{e.message}" }
    end

    sig do
      params(
        value: T.untyped,
        depth: Integer,
        seen: T.nilable(T::Set[Integer])
      ).returns(T.untyped)
    end
    def self.scrub_value(value, depth: 0, seen: nil)
      seen ||= Set.new
      case value
      when String
        Text.scrub(value)
      when Hash
        # A cycle or an absurd depth is left as is; `sanitize_value` marks it later.
        return value if depth >= PayloadLimits::MAX_WALK_DEPTH || !seen.add?(value.object_id)

        result = value.each_with_object({}) do |(key, item), acc|
          acc[key.is_a?(String) ? Text.scrub(key) : key] = scrub_value(item, depth: depth + 1, seen: seen)
        end
        seen.delete(value.object_id)
        result
      when Array
        return value if depth >= PayloadLimits::MAX_WALK_DEPTH || !seen.add?(value.object_id)

        result = value.map { |item| scrub_value(item, depth: depth + 1, seen: seen) }
        seen.delete(value.object_id)
        result
      else
        value
      end
    end

    sig { params(value: T.untyped).returns(T.untyped) }
    def self.sanitize_response(value)
      case value
      when Hash
        sanitize_response_hash(value)
      when Array
        value.map { |block| sanitize_content_block(block) }
      else
        value
      end
    end

    sig { params(response: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def self.sanitize_response_hash(response)
      content = response[:content] || response["content"]
      if content.is_a?(Array)
        response[:content] = content.map { |block| sanitize_content_block(block) }
        response.delete("content") if response.key?("content")
      end
      structured = response[:structured_content] || response[:structuredContent] || response["structuredContent"]
      if structured.is_a?(Hash)
        response[:structuredContent] = sanitize_value(structured)
        response.delete("structuredContent") if response.key?("structuredContent")
      end
      response
    end

    sig { params(block: T.untyped).returns(T.untyped) }
    def self.sanitize_content_block(block)
      return block unless block.is_a?(Hash)

      type = block[:type] || block["type"]
      case type
      when "text", "resource_link"
        block
      when "image"
        text_block(IMAGE_REDACTED)
      when "audio"
        text_block(AUDIO_REDACTED)
      when "resource"
        blob?(block) ? text_block(BINARY_RESOURCE_REDACTED) : block
      else
        text_block(format(UNSUPPORTED_TYPE_PATTERN, type.to_s))
      end
    end

    # Depth- and identity-bounded so circular or absurdly deep structures still terminate.
    sig do
      params(
        value: T.untyped,
        depth: Integer,
        seen: T.nilable(T::Set[Integer])
      ).returns(T.untyped)
    end
    def self.sanitize_value(value, depth: 0, seen: nil)
      seen ||= Set.new
      case value
      when String
        sanitize_string(value)
      when Hash
        return PayloadLimits::MAX_DEPTH_EXCEEDED_MARKER if depth >= AgentCat::PayloadLimits::MAX_WALK_DEPTH
        return PayloadLimits::CIRCULAR_MARKER unless seen.add?(value.object_id)

        value.each_with_object({}) do |(key, item), acc|
          acc[key] = sanitize_value(item, depth: depth + 1, seen: seen)
        end
      when Array
        return PayloadLimits::MAX_DEPTH_EXCEEDED_MARKER if depth >= AgentCat::PayloadLimits::MAX_WALK_DEPTH
        return PayloadLimits::CIRCULAR_MARKER unless seen.add?(value.object_id)

        value.map { |item| sanitize_value(item, depth: depth + 1, seen: seen) }
      else
        value
      end
    end

    sig { params(string: String).returns(String) }
    def self.sanitize_string(string)
      return string if string.bytesize < AgentCat::PayloadLimits::BASE64_SIZE_GATE

      BASE64_PATTERN.match?(string) ? BINARY_DATA_REDACTED : string
    end

    sig { params(text: String).returns(T::Hash[Symbol, String]) }
    def self.text_block(text)
      {type: "text", text: text}
    end

    # A "resource" content block wraps an `EmbeddedResourceContent`: {type: "resource",
    # resource: {uri:, blob:|text:, mimeType:}}. `blob` lives two levels down, not on the
    # block itself — checking `block[:blob]` directly never matches a real MCP resource
    # block (only the pre-fix test's flattened, non-spec fixture), so binary resource data
    # was never actually redacted on the real path.
    sig { params(block: T::Hash[T.untyped, T.untyped]).returns(T::Boolean) }
    def self.blob?(block)
      resource = block[:resource] || block["resource"]
      !!(resource.is_a?(Hash) && (resource.key?(:blob) || resource.key?("blob")))
    end
    private_class_method :blob?
  end
end
