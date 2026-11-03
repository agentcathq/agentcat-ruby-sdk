# typed: true

require_relative "hooks"

module AgentCat
  # Applies `Options#redact_event`/`#redact_sensitive_information` to an event. Shared
  # by `Interceptor` (every tool-call event) and `AgentCat.publish_custom_event` (events
  # built outside any tool call). Runs on the queue's worker thread, via `EventPipeline`.
  module Redaction
    extend T::Sig

    # Not the hook's to change: these decide where and how the event gets ingested. Same
    # five fields TS (`RESTORED_FIELDS`) and Go (`ApplyEventRedaction`) put back.
    RESTORED_FIELDS = T.let(%i[id session_id project_id event_type timestamp].freeze, T::Array[Symbol])

    sig { params(event: UnredactedEvent, options: AgentCat::Options).returns(T.nilable(UnredactedEvent)).checked(:tests) }
    def self.apply_redact_event(event, options)
      hook = options.redact_event
      return event unless hook

      # Snapshot first - a hook that mutates in place has already changed `event` by
      # the time it returns.
      original = RESTORED_FIELDS.to_h { |field| [field, event.public_send(field)] }
      result = Hooks.run(hook, event, timeout: options.hook_timeout, name: "redact_event")
      return nil if result.nil?

      kept = if !result.is_a?(UnredactedEvent)
        Log.warn("redact_event hook returned #{result.class}, not the event or nil; its result is ignored")
        event
      elsif result.equal?(event)
        event
      else
        warn_detached(result)
      end
      restore(kept, original)
    end

    # Raised when the string hook didn't hand back a string for some value.
    class StringRedactionFailed < StandardError; end

    # nil drops the event: if the hook raised, timed out or returned a non-String for
    # any one value, we can't tell what's still unredacted, so nothing goes out.
    #
    # Same fields as TS's `redactEvent`: everything an actor or a tool put on the event
    # (parameters, user_intent, response, identify_data, and the whole error - message,
    # stack, frames, chained errors). TS's `PROTECTED_FIELDS` leaves `properties` and
    # `tags` alone: they are the customer's own metadata, not captured traffic.
    sig { params(event: UnredactedEvent, options: AgentCat::Options).returns(T.nilable(UnredactedEvent)).checked(:tests) }
    def self.apply_sensitive_redaction(event, options)
      hook = options.redact_sensitive_information
      return event unless hook

      worker = Hooks::Worker.new(hook, timeout: options.hook_timeout)
      redacter = ->(value) { value.is_a?(String) ? redact_string(worker, value) : value }
      event.parameters = deep_map(event.parameters, &redacter)
      unless event.user_intent.nil?
        event.user_intent = redact_string(worker, T.must(event.user_intent))
      end
      event.response = deep_map(event.response, &redacter)
      event.identify_data = deep_map(event.identify_data, &redacter)
      event.error = deep_map(event.error, &redacter)
      event
    rescue StringRedactionFailed
      Log.warn(
        "redact_sensitive_information raised, timed out or returned a non-String; " \
        "event dropped so nothing goes out unredacted"
      )
      nil
    ensure
      worker&.close
    end

    sig { params(worker: Hooks::Worker, string: String).returns(String).checked(:tests) }
    def self.redact_string(worker, string)
      result = worker.call(string)
      raise StringRedactionFailed unless result.is_a?(String)

      result
    end
    private_class_method :redact_string

    sig { params(value: T.untyped, block: T.proc.params(arg: String).returns(String)).returns(T.untyped).checked(:tests) }
    def self.deep_map(value, &block)
      case value
      when Hash
        value.each_with_object({}) { |(k, v), acc| acc[k] = deep_map(v, &block) }
      when Array
        value.map { |v| deep_map(v, &block) }
      when String
        block.call(value)
      else
        value
      end
    end
    private_class_method :deep_map
    private_constant :StringRedactionFailed

    sig { params(event: UnredactedEvent, original: T::Hash[Symbol, T.untyped]).returns(UnredactedEvent) }
    def self.restore(event, original)
      original.each { |field, value| event.public_send(:"#{field}=", value) }
      event
    end
    private_class_method :restore

    sig { params(event: UnredactedEvent).returns(UnredactedEvent) }
    def self.warn_detached(event)
      Log.warn(
        "redact_event hook returned a new object instead of mutating and returning the event it was " \
        "given. Every field it did not set was dropped. Mutate and return the same UnredactedEvent."
      )
      event
    end
    private_class_method :warn_detached
  end
end
