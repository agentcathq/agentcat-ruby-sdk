# typed: strict

require "json"

module AgentCat
  # Rough token counts for the `input_tokens`/`output_tokens` fields on tool-call events.
  #
  # Same formula as the Go/TS/Python SDKs, byte for byte: ceil(utf8_bytes / 3.5), clamped
  # to int32 (the server's columns). 3.5 sits between what OpenAI's tokenizers (~3.7
  # bytes/token) and Claude's (~3.15) do on real MCP responses.
  #
  # Input is the raw arguments the agent sent, injected params included, as compact JSON.
  # Output is the text of the content blocks the agent reads back - images, blobs and
  # `structuredContent` don't count unless there's nothing else to go on (see
  # `output_tokens`).
  #
  # Never raises: this runs on the tool call's own path, so a value that won't encode
  # costs the field, not the call.
  module TokenEstimate
    extend T::Sig

    BYTES_PER_TOKEN = 3.5
    MAX_TOKEN_COUNT = 2_147_483_647

    sig { params(byte_count: Integer).returns(Integer) }
    def self.estimate(byte_count)
      return 0 if byte_count <= 0

      [(byte_count / BYTES_PER_TOKEN).ceil, MAX_TOKEN_COUNT].min
    end

    # nil when there are no arguments at all; `{}` counts as `{}`.
    sig { params(arguments: T.untyped).returns(T.nilable(Integer)) }
    def self.input_tokens(arguments)
      return nil if arguments.nil?

      bytes = compact_json_bytes(arguments)
      bytes && estimate(bytes)
    end

    # nil when there's no response (the tool raised). A response with no `content` list
    # is counted whole; an empty `content` list falls back to `structuredContent`.
    sig { params(response: T.untyped).returns(T.nilable(Integer)) }
    def self.output_tokens(response)
      return nil unless response.is_a?(Hash)

      content = fetch(response, :content)
      unless content.is_a?(Array)
        bytes = compact_json_bytes(response)
        return bytes && estimate(bytes)
      end

      if content.empty?
        structured = fetch(response, :structuredContent)
        return 0 if structured.nil?

        bytes = compact_json_bytes(structured)
        return bytes && estimate(bytes)
      end

      estimate(content.sum { |block| content_block_bytes(block) })
    rescue
      nil
    end

    # Text blocks and embedded text resources are what the agent actually reads.
    sig { params(block: T.untyped).returns(Integer) }
    def self.content_block_bytes(block)
      return 0 unless block.is_a?(Hash)

      text = case fetch(block, :type).to_s
      when "text" then fetch(block, :text)
      when "resource"
        resource = fetch(block, :resource)
        resource.is_a?(Hash) ? fetch(resource, :text) : nil
      end
      text.is_a?(String) ? text.bytesize : 0
    end

    # Ruby's JSON doesn't escape `<`, `>`, `&` or non-ASCII, so this matches what
    # `JSON.stringify` produces in the TS SDK.
    sig { params(value: T.untyped).returns(T.nilable(Integer)) }
    def self.compact_json_bytes(value)
      JSON.generate(value).bytesize
    rescue
      nil
    end

    # Results come back symbol-keyed from `MCP::Tool::Response#to_h`, string-keyed from a
    # tool that returns a plain Hash.
    sig { params(hash: T::Hash[T.untyped, T.untyped], key: Symbol).returns(T.untyped) }
    def self.fetch(hash, key)
      hash.key?(key) ? hash[key] : hash[key.to_s]
    end

    private_class_method :content_block_bytes, :compact_json_bytes, :fetch
  end
end
