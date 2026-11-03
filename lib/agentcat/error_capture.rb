# typed: true

require_relative "payload_limits"
require_relative "truncation"

module AgentCat
  # Converts a raised exception into the structured error payload the Go and TypeScript
  # SDKs send: message, type, platform, a raw stack string, structured frames (function/
  # filename/lineno/in_app), and the `#cause` chain. Ruby's `backtrace_locations` already
  # gives structured frames for free - no need to parse a stack-trace string the way the
  # Go SDK does.
  #
  # Never raises: a malformed error (a custom #message that itself raises, for example)
  # falls back to a minimal payload rather than taking the publish pipeline down with it.
  module ErrorCapture
    extend T::Sig

    PLATFORM = "ruby"

    sig { params(error: Exception).returns(T::Hash[String, T.untyped]) }
    def self.capture(error)
      {
        "message" => safe_message(error),
        "type" => error.class.name,
        "platform" => PLATFORM
      }.merge(stack_and_frames(error)).merge(chain(error))
    rescue => e
      {
        "message" => "[error capture failed: #{e.class}: #{e.message}]",
        "type" => error.class.name,
        "platform" => PLATFORM
      }
    end

    # The error of an isError tool result with no exception behind it, like the TS
    # SDK's `captureCallToolResultError`: its text blocks joined by a space as the
    # message, no type and no stack. nil for a result that isn't an isError result.
    sig { params(result: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
    def self.capture_result(result)
      return nil unless result.is_a?(Hash)

      flag = result.key?(:isError) ? result[:isError] : result["isError"]
      content = result.key?(:content) ? result[:content] : result["content"]
      return nil unless flag == true && content.is_a?(Array)

      texts = content.filter_map do |block|
        next if !block.is_a?(Hash) || (block[:type] || block["type"]) != "text"

        block.key?(:text) ? block[:text] : block["text"]
      end
      message = texts.join(" ").strip
      {"message" => message.empty? ? "Unknown error" : message, "platform" => PLATFORM}
    end

    sig { params(error: Exception).returns(T::Hash[String, T.untyped]) }
    def self.stack_and_frames(error)
      backtrace = error.backtrace
      return {} if backtrace.nil? || backtrace.empty?

      result = T.let({"stack" => backtrace.join("\n")}, T::Hash[String, T.untyped])
      frames = frames_from(error)
      result["frames"] = Truncation.truncate_frames(frames) unless frames.empty?
      result
    end
    private_class_method :stack_and_frames

    sig { params(error: Exception).returns(T::Array[T::Hash[String, T.untyped]]) }
    def self.frames_from(error)
      locations = error.backtrace_locations
      return [] if locations.nil?

      locations.map do |location|
        path = location.absolute_path || location.path
        {
          "function" => location.label,
          "filename" => location.path,
          "abs_path" => path,
          "lineno" => location.lineno,
          "in_app" => in_app?(path)
        }
      end
    end
    private_class_method :frames_from

    # Library/stdlib frames (this gem included) are noise next to the tool's own code.
    sig { params(path: T.nilable(String)).returns(T::Boolean) }
    def self.in_app?(path)
      return true if path.nil?

      !(Gem.path.any? { |gem_dir| path.start_with?(gem_dir) } || path.start_with?(RbConfig::CONFIG["rubylibdir"]))
    end
    private_class_method :in_app?

    sig { params(error: Exception).returns(T::Hash[String, T.untyped]) }
    def self.chain(error)
      chained = []
      seen = Set.new
      current = T.let(error.cause, T.nilable(Exception))
      while current && seen.add?(current.object_id) && chained.size < PayloadLimits::MAX_CHAIN_DEPTH
        entry = T.let({"message" => safe_message(current), "type" => current.class.name}, T::Hash[String, T.untyped])
        entry.merge!(stack_and_frames(current))
        chained << entry
        current = current.cause
      end
      chained.empty? ? {} : {"chained_errors" => chained}
    end
    private_class_method :chain

    sig { params(error: Exception).returns(String) }
    def self.safe_message(error)
      error.message.to_s
    rescue => e
      "[message capture failed: #{e.class}]"
    end
    private_class_method :safe_message
  end
end
