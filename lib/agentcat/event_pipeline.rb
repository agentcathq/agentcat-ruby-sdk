# typed: true

require_relative "redaction"
require_relative "sanitization"
require_relative "truncation"
require_relative "delivery"
require_relative "exporters"

module AgentCat
  # What happens to an event once it's on the queue's worker thread: redact, sanitize,
  # truncate, deliver, export. Shared by tool calls and tracked custom events so the two
  # can't drift apart.
  module EventPipeline
    extend T::Sig

    # `label` only goes into debug logs, to say which event failed. `redact_strings:
    # false` skips `redact_sensitive_information`: custom events hold only what the
    # customer chose to send, so TS never runs the string hook on them.
    # `redact_event` still runs, as in TS.
    sig { params(event: UnredactedEvent, tracker: Tracker, epoch: Integer, label: String, redact_strings: T::Boolean).void }
    def self.run(event, tracker, epoch:, label:, redact_strings: true)
      options = tracker.options

      # The hooks get valid UTF-8, so a regex in them can't raise on a binary string.
      Sanitization.scrub_event(event)

      # Runs here, not before enqueue: matching Go/TS/Python, a slow or uncached redact
      # hook must never add latency to the caller.
      redacted = Redaction.apply_redact_event(event, options)
      return if redacted.nil?

      event = redact_strings ? Redaction.apply_sensitive_redaction(redacted, options) : redacted
      return if event.nil?

      normalize(event, label: label)
      return if record_in_fake(event, epoch)

      # No project id = export-only, skip AgentCat's own API entirely.
      if tracker.project_id
        Delivery.publish(
          options.client,
          event.to_wire_hash,
          max_retries: options.max_retries,
          base_delay: options.retry_base_delay,
          epoch: epoch
        )
      end
      Exporters.dispatch(options.exporters, event)
    end

    # `AgentCat.fake`: the event goes to the fake (as it would be sent) instead of
    # AgentCat and the exporters. Returns whether it did. An event from before a
    # `reset!` is dropped, like Delivery does.
    sig { params(event: UnredactedEvent, epoch: Integer).returns(T::Boolean) }
    def self.record_in_fake(event, epoch)
      fake = AgentCat.active_fake
      return false if fake.nil?

      fake.record(event.to_wire_hash) if epoch == AgentCat.event_epoch
      true
    end

    # Fail open like Go/Python: a bug in either step delivers the event as-is rather
    # than dropping it. The UTF-8 scrub runs first and on its own (it never raises), so
    # even then every string encodes as JSON. It runs again here because a hook can put
    # new strings on the event, and untracked custom events come here without `run`.
    sig { params(event: UnredactedEvent, label: String).void }
    def self.normalize(event, label:)
      Sanitization.scrub_event(event)
      sanitize_and_truncate(event, label: label)
    end

    sig { params(event: UnredactedEvent, label: String).void }
    def self.sanitize_and_truncate(event, label:)
      Sanitization.sanitize_event(event)
      Truncation.truncate_event(event)
    rescue => e
      Log.warn("sanitizing or truncating #{label} failed with #{e.class}; the event goes out as it is")
      AgentCat.logger.debug { "sanitization/truncation failed for #{label}: #{e.class}: #{e.message}" }
    end
  end
end
