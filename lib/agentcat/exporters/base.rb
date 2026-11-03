# typed: true

require "json"
require "time"
require_relative "../http_post"
require_relative "trace_context"

module AgentCat
  module Exporters
    # Base class for forwarding events to a third-party telemetry store. Subclass and
    # implement #export!. By the time you get the event it's already redacted — it
    # carries exactly what's allowed to leave the process. If your exporter raises,
    # Exporters.dispatch catches and logs it; it costs you this event, not the call.
    #
    # #http_post is the default sender for HTTP-based exporters. Swap it out (override,
    # or pass http_post: to the initializer) for tests or to route through a proxy.
    #
    # An exporter that can't work (no api_key, a DSN it can't parse) doesn't raise from
    # its initializer: it logs one ERROR line, keeps the reason in
    # #setup_error and exports nothing.
    class Base
      extend T::Sig

      # TS's fetch has no timeout at all. These timeouts are shorter: a
      # dead vendor holds the queue's worker at most this long per request.
      OPEN_TIMEOUT = 2
      TOTAL_TIMEOUT = 10

      # TS's `AGENTCAT_SOURCE` (src/modules/constants.ts).
      SOURCE = "agentcat"
      TOOLS_CALL = "mcp:tools/call"

      # Why this exporter is off, or nil when it works.
      sig { returns(T.nilable(String)) }
      attr_reader :setup_error

      sig { params(event: UnredactedEvent).void }
      def export(event)
        return if @setup_error

        export!(event)
      end

      # Implement in subclasses. `event` is an already-redacted UnredactedEvent.
      sig { params(event: UnredactedEvent).void }
      def export!(event)
        raise NotImplementedError, "#{self.class} must implement #export!"
      end

      # Returns [status, response_body]. A non-2xx status isn't an exception here —
      # that's the caller's call. No User-Agent of our own: TS sets none either.
      sig { params(url: String, headers: T::Hash[String, String], body: String).returns([Integer, String]) }
      def http_post(url, headers, body)
        HttpPost.call(url, headers, body, open_timeout: OPEN_TIMEOUT, read_timeout: TOTAL_TIMEOUT, deadline: TOTAL_TIMEOUT)
      end

      private

      # Every HTTP exporter's initializer takes http_post: for this reason.
      sig { params(http_post: T.untyped).returns(T.untyped) }
      def resolve_http_post(http_post)
        http_post || method(:http_post)
      end

      sig { params(exporter_name: String, url: String, headers: T::Hash[String, String], payload: T.untyped).void }
      def post_json!(exporter_name, url, headers, payload)
        post!(exporter_name, url, headers, payload.to_json)
      end

      sig { params(exporter_name: String, url: String, headers: T::Hash[String, String], body: String).void }
      def post!(exporter_name, url, headers, body)
        status, response = T.unsafe(@http_post).call(url, headers, body)
        raise "#{exporter_name} returned HTTP #{status}: #{response}" unless status.between?(200, 299)
      end

      # Turns the exporter off. Call it from the initializer, instead of raising.
      sig { params(reason: String).void }
      def setup_failed!(reason)
        @setup_error = T.let(reason, T.nilable(String))
        AgentCat.logger.error("#{reason}. This exporter is off and exports nothing.")
      end

      sig { params(value: T.untyped).returns(T::Boolean) }
      def blank?(value)
        value.nil? || (value.is_a?(String) && value.strip.empty?)
      end

      # JavaScript truthiness, for the many `if (event.x)` checks the TS exporters make:
      # nil, false, "" and 0 are false.
      sig { params(value: T.untyped).returns(T::Boolean) }
      def truthy?(value)
        !(value.nil? || value == false || value == "" || (value.is_a?(Numeric) && value.zero?))
      end

      # The event time in Unix milliseconds, like TS's `event.timestamp.getTime()`.
      sig { params(event: UnredactedEvent).returns(Integer) }
      def event_millis(event)
        (Time.iso8601(event.timestamp).to_r * 1000).floor
      rescue ArgumentError
        (Time.now.to_r * 1000).floor
      end

      # A JavaScript number in JSON: 1.0 prints as 1, like JSON.stringify.
      sig { params(value: Numeric).returns(Numeric) }
      def js_number(value)
        return value unless value.is_a?(Float) && value.finite?

        (value % 1).zero? ? value.to_i : value
      end

      sig { params(millis: Integer).returns(String) }
      def iso_millis(millis)
        Time.at(Rational(millis, 1000)).utc.iso8601(3)
      end

      # TS hands its exporters the event as it goes to AgentCat: the SDK's own tags
      # (agentcat_session_id_source, ...) are in `tags`, so they are here too.
      sig { params(event: UnredactedEvent).returns(T.nilable(T::Hash[String, String])) }
      def wire_tags(event)
        event.to_wire_hash[:tags]
      end

      sig { params(event: UnredactedEvent).returns(T.nilable(T::Hash[String, T.untyped])) }
      def wire_properties(event)
        event.to_wire_hash[:properties]
      end

      sig { params(event: UnredactedEvent).returns(T.nilable(String)) }
      def session_id(event)
        id = event.session_id
        (id.nil? || id.empty?) ? nil : id
      end
    end
  end
end
