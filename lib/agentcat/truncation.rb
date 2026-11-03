# typed: true

require "json"
require_relative "payload_limits"
require_relative "text"

module AgentCat
  # Ports the Go SDK's internal/truncation (itself a port of the TypeScript one).
  # Runs after sanitization; if it raises, the interceptor just logs and delivers
  # anyway, same fail-open behavior as Go/Python.
  #
  # Three passes: cap individual fields (user_intent, names, error message, stack
  # frames, response text), recursively normalize everything else (32K strings,
  # 100 entries per hash/array, depth 10), then if it's still over the 100KB budget,
  # re-normalize shallower and start trimming the biggest strings.
  #
  # String limits count UTF-16 code units, like TS `String#length`, and the "..."
  # suffix goes on top of the limit, as in TS. Only the total event budget counts
  # bytes of the encoded JSON, as TS does.
  module Truncation
    extend T::Sig

    USER_FIELDS = [:parameters, :response, :identify_data, :error, :properties].freeze

    sig { params(event: UnredactedEvent).void }
    def self.truncate_event(event)
      limit_field(event, :user_intent, PayloadLimits::MAX_USER_INTENT_LENGTH)
      limit_field(event, :resource_name, PayloadLimits::MAX_RESOURCE_NAME_LENGTH)
      limit_field(event, :server_name, PayloadLimits::MAX_METADATA_LENGTH)
      limit_field(event, :server_version, PayloadLimits::MAX_METADATA_LENGTH)
      limit_field(event, :client_name, PayloadLimits::MAX_METADATA_LENGTH)
      limit_field(event, :client_version, PayloadLimits::MAX_METADATA_LENGTH)
      limit_field(event, :identify_actor_given_id, PayloadLimits::MAX_METADATA_LENGTH)
      limit_field(event, :identify_actor_name, PayloadLimits::MAX_METADATA_LENGTH)
      truncate_error_fields(T.must(event.error)) if event.error.is_a?(Hash)
      truncate_response_blocks(event.response) if event.response.is_a?(Hash)

      event.parameters = normalize(event.parameters, PayloadLimits::MAX_DEPTH)
      event.response = normalize(event.response, PayloadLimits::MAX_DEPTH)
      event.identify_data = normalize(event.identify_data, PayloadLimits::MAX_DEPTH)
      event.error = normalize(event.error, PayloadLimits::MAX_DEPTH)
      event.properties = normalize(event.properties, PayloadLimits::MAX_DEPTH)

      truncate_to_size(event)
    end

    sig { params(event: UnredactedEvent, field: Symbol, limit: Integer).void }
    def self.limit_field(event, field, limit)
      value = event.public_send(field)
      event.public_send("#{field}=", truncate_string(value, limit)) if value.is_a?(String)
    end

    sig { params(error: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def self.truncate_error_fields(error)
      message_key = error.key?("message") ? "message" : :message
      value = error[message_key]
      error[message_key] = truncate_string(value, PayloadLimits::MAX_ERROR_MESSAGE_LENGTH) if value.is_a?(String)

      frames_key = error.key?("frames") ? "frames" : :frames
      frames = error[frames_key]
      error[frames_key] = truncate_frames(frames) if frames.is_a?(Array)
      error
    end

    sig { params(frames: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def self.truncate_frames(frames)
      half = PayloadLimits::MAX_STACK_FRAMES / 2
      return frames if frames.size <= PayloadLimits::MAX_STACK_FRAMES

      frames.first(half) + frames.last(half)
    end

    # Caps text in each content block, leaves the rest of the response alone.
    sig { params(response: T::Hash[T.untyped, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def self.truncate_response_blocks(response)
      content = response[:content] || response["content"]
      if content.is_a?(Array)
        content.each do |block|
          next unless block.is_a?(Hash)

          # Write back under the key the block uses, so a string-keyed block doesn't
          # end up with both "text" and :text.
          text_key = block.key?(:text) ? :text : "text"
          text = block[text_key]
          next unless text.is_a?(String)

          block[text_key] = truncate_string(text, PayloadLimits::MAX_CONTENT_TEXT_LENGTH)
        end
      end
      response
    end

    # Length-capped strings, breadth-capped hashes/arrays, depth-capped nesting — a
    # hostile payload can't survive this untouched.
    sig { params(value: T.untyped, depth: Integer, seen: T.nilable(T::Set[Integer])).returns(T.untyped) }
    def self.normalize(value, depth, seen = nil)
      seen ||= Set.new
      case value
      when Hash
        return PayloadLimits::CIRCULAR_MARKER unless seen.add?(value.object_id)
        return PayloadLimits::OBJECT_DEPTH_MARKER if depth <= 0

        result = {}
        value.each_with_index do |(key, item), index|
          if index >= PayloadLimits::MAX_BREADTH
            result[PayloadLimits::TRUNCATION_SUFFIX] = PayloadLimits::MAX_BREADTH_MARKER
            break
          end
          result[key] = normalize(item, depth - 1, seen)
        end
        seen.delete(value.object_id)
        result
      when Array
        return PayloadLimits::CIRCULAR_MARKER unless seen.add?(value.object_id)
        return PayloadLimits::ARRAY_DEPTH_MARKER if depth <= 0

        out = []
        value.each_with_index do |item, index|
          break if index >= PayloadLimits::MAX_BREADTH

          out << normalize(item, depth - 1, seen)
        end
        out << PayloadLimits::MAX_BREADTH_MARKER if value.size > PayloadLimits::MAX_BREADTH
        seen.delete(value.object_id)
        out
      when String
        truncate_string(value, PayloadLimits::MAX_STRING_LENGTH)
      when Float
        return "[NaN]" if value.nan?
        return (value.positive? ? "[Infinity]" : "[-Infinity]") if value.infinite?

        value
      when nil, true, false, Numeric
        value
      else
        normalize_non_primitive(value)
      end
    end

    sig { params(value: T.untyped).returns(T.untyped) }
    def self.normalize_non_primitive(value)
      case value
      when Symbol
        Text.scrub(value.to_s)
      when Time
        value.iso8601
      else
        json_safe = begin
          JSON.generate(value)
        rescue JSON::GeneratorError, TypeError
          nil
        end
        json_safe ? value : Text.scrub(value.to_s)
      end
    end

    # Re-normalizes at shrinking depths until it fits, then falls back to trimming.
    # `error` never goes below MIN_ERROR_DEPTH (not in TS): shallower, its
    # `frames` and `chained_errors[].frames` become markers and the backend can't
    # build an issue from them.
    sig { params(event: UnredactedEvent).void }
    def self.truncate_to_size(event)
      return if event_bytes(event) <= PayloadLimits::MAX_EVENT_BYTES

      (PayloadLimits::MAX_DEPTH - 1).downto(1) do |depth|
        USER_FIELDS.each do |field|
          value = event.public_send(field)
          next if value.nil?

          field_depth = (field == :error) ? [depth, PayloadLimits::MIN_ERROR_DEPTH].max : depth
          event.public_send("#{field}=", normalize(value, field_depth))
        end
        break if event_bytes(event) <= PayloadLimits::MAX_EVENT_BYTES
      end

      trim_largest_strings(event) if event_bytes(event) > PayloadLimits::MAX_EVENT_BYTES
    end

    # Last resort: cut the biggest strings first until it fits. Mirrors TS
    # truncateLargestFields: the allowance is the byte excess plus a 200 buffer for the
    # suffix, a cut is in UTF-16 code units, never more than half a string, skips
    # cuts under 10, gives up after 10 passes.
    sig { params(event: UnredactedEvent).void }
    def self.trim_largest_strings(event)
      10.times do
        break if event_bytes(event) <= PayloadLimits::MAX_EVENT_BYTES

        excess = event_bytes(event) - PayloadLimits::MAX_EVENT_BYTES
        allowance = excess + 200
        largest_strings(event).each do |path, length|
          excess = event_bytes(event) - PayloadLimits::MAX_EVENT_BYTES
          break if excess <= 0

          allowance = excess + 200
          current = value_at(event, path)
          cut = [length / 2, allowance].min
          next if cut < 10

          replace_at(event, path, truncate_string(current, length - cut))
        end
      end
    end

    # [[path, length], ...] for every string over 100 UTF-16 code units, longest first.
    sig { params(event: UnredactedEvent).returns(T::Array[[T::Array[T.untyped], Integer]]) }
    def self.largest_strings(event)
      found = []
      stack = T.let(
        [*USER_FIELDS.filter_map { |field|
          value = event.public_send(field)
          [value, [field]] unless value.nil?
        }],
        T::Array[[T.untyped, T::Array[T.untyped]]]
      )
      until stack.empty?
        value, path = stack.pop
        case value
        when Hash
          value.each { |key, item| stack << [item, T.must(path) + [key]] }
        when Array
          value.each_with_index { |item, index| stack << [item, T.must(path) + [index]] }
        when String
          length = Text.utf16_length(value)
          found << [path, length] if length > 100
        end
      end
      found.sort_by { |(_path, length)| -length }
    end

    sig { params(event: UnredactedEvent, path: T::Array[T.untyped]).returns(T.untyped) }
    def self.value_at(event, path)
      root = event.public_send(T.must(path.first))
      tail = T.must(path[1..])
      tail.reduce(root) { |acc, segment| (acc.is_a?(Hash) || acc.is_a?(Array)) ? acc[segment] : acc }
    end

    sig { params(event: UnredactedEvent, path: T::Array[T.untyped], value: T.untyped).void }
    def self.replace_at(event, path, value)
      if path.length == 1
        event.public_send("#{T.must(path.first)}=", value)
        return
      end

      root = event.public_send(T.must(path.first))
      parent = T.must(path[1..-2]).reduce(root) { |acc, segment| acc[segment] }
      parent[T.must(path.last)] = value
    end

    sig { params(event: UnredactedEvent).returns(Integer) }
    def self.event_bytes(event)
      JSON.generate(event.to_wire_hash).bytesize
    end

    # TS `truncateString`: over `max` UTF-16 code units keeps the first `max` and adds
    # "...". Scrubs invalid UTF-8 and never splits a character, so the result always
    # encodes as JSON.
    sig { params(value: String, max: Integer).returns(String) }
    def self.truncate_string(value, max)
      value = Text.scrub(value)
      return value unless Text.exceeds_utf16?(value, max)

      "#{Text.utf16_slice(value, max)}#{PayloadLimits::TRUNCATION_SUFFIX}"
    end
  end
end
