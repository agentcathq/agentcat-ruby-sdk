# typed: true

require_relative "diagnostics"

module AgentCat
  # Retries a failed publish with exponential backoff and jitter, then gives up. Kept
  # separate from Client because the generated client has no opinion on retry policy.
  # Runs on the queue's worker thread, so the sleeps here never touch a tool call.
  #
  # Defaults: 3 retries after the first attempt, 1s base doubling (~1s, 2s, 4s) plus
  # jitter, 10s HTTP timeout per attempt. Override via Options#max_retries /
  # #retry_base_delay / #request_timeout.
  class Delivery
    extend T::Sig

    DEFAULT_MAX_RETRIES = 3
    DEFAULT_BASE_DELAY_SECONDS = 1.0
    JITTER_RATIO = 0.25

    sig do
      params(
        client: T.untyped,
        event: T::Hash[Symbol, T.untyped],
        max_retries: Integer,
        base_delay: Numeric,
        epoch: T.nilable(Integer)
      ).void
    end
    def self.publish(client, event, max_retries: DEFAULT_MAX_RETRIES, base_delay: DEFAULT_BASE_DELAY_SECONDS, epoch: nil)
      attempt = 0
      loop do
        # epoch is captured at enqueue time. If AgentCat got reset since (test
        # teardown, usually), this event is stale and shouldn't publish into
        # whatever state the process is in now.
        return if epoch && epoch != AgentCat.event_epoch

        return if client.post_event(event)

        if attempt >= max_retries
          Log.error("event publish failed after #{max_retries + 1} attempts; the event is lost")
          Diagnostics.record(:error, "AgentCat runtime error | event publish failed after #{max_retries + 1} attempts | project #{event[:project_id] || "(telemetry-only)"}")
          return
        end

        sleep(backoff(attempt + 1, base: base_delay))
        attempt += 1
      end
    end

    # attempt is 1-based: base * 2^(attempt-1), plus jitter up to JITTER_RATIO of
    # base. Random.rand, not Kernel#rand — Kernel#rand won't scale a Float below 1.0.
    sig { params(attempt: Integer, base: Numeric).returns(Float) }
    def self.backoff(attempt, base: DEFAULT_BASE_DELAY_SECONDS)
      exponentiated = T.must(base.to_f) * (2**(attempt - 1))
      (exponentiated + Random.rand(exponentiated * JITTER_RATIO)).to_f
    end
  end
end
