# typed: true

module AgentCat
  module Exporters
    # Posts one span per event to an OpenTelemetry collector as OTLP/HTTP JSON, like
    # TS's src/modules/exporters/otlp.ts. Plain Net::HTTP, no gem. Each event is its
    # own request, so nothing waits in a batch at exit.
    #
    #   AgentCat.track(server, project_id, AgentCat::Options.new(
    #     exporters: [AgentCat::Exporters::Otlp.new(endpoint: "http://localhost:4318")]
    #   ))
    #
    # Keys (TS names in snake_case): endpoint (required; /v1/traces is added when the
    # path does not end with it) and headers. Ruby only: http_post, and tracer: an
    # OpenTelemetry tracer of your own to emit the span through instead of posting it.
    # That tracer's provider owns batching, resource attributes and shutdown.
    class Otlp < Base
      extend T::Sig

      TRACES_PATH = "/v1/traces"
      SPAN_KIND_SERVER = 2
      STATUS_OK = 1
      STATUS_ERROR = 2

      CONFIG_KEYS = {
        "endpoint" => :endpoint, "headers" => :headers, "tracer" => :tracer, "http_post" => :http_post
      }.freeze

      sig { returns(T.nilable(String)) }
      attr_reader :endpoint

      sig { returns(T::Hash[String, String]) }
      attr_reader :headers

      sig do
        params(
          endpoint: T.nilable(String),
          headers: T::Hash[T.any(String, Symbol), String],
          tracer: T.untyped,
          http_post: T.untyped
        ).void
      end
      def initialize(endpoint: nil, headers: {}, tracer: nil, http_post: nil)
        @headers = T.let({"Content-Type" => "application/json"}.merge(headers.transform_keys(&:to_s)), T::Hash[String, String])
        @tracer = tracer
        return if tracer

        if blank?(endpoint)
          setup_failed!("OTLP exporter needs an endpoint or a tracer")
          return
        end

        # TS otlp.ts:18-19: drop trailing slashes, then add /v1/traces unless it is there.
        url = T.must(endpoint).sub(%r{/+\z}, "")
        @endpoint = T.let(url.end_with?(TRACES_PATH) ? url : "#{url}#{TRACES_PATH}", T.nilable(String))
        @http_post = resolve_http_post(http_post)
      end

      sig { params(event: UnredactedEvent).void }
      def export!(event)
        return emit_through_tracer(event) if @tracer

        post_json!("OTLP", T.must(@endpoint), @headers, request(event))
      end

      private

      # TS otlp.ts:33-59: service.name is the MCP server's name.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def request(event)
        {
          resourceSpans: [{
            resource: {
              attributes: [
                {key: "service.name", value: {stringValue: truthy?(event.server_name) ? event.server_name : "mcp-server"}},
                {key: "service.version", value: {stringValue: truthy?(event.server_version) ? event.server_version : "unknown"}}
              ]
            },
            scopeSpans: [{
              scope: {name: SOURCE, version: truthy?(event.agentcat_version) ? event.agentcat_version : "unknown"},
              spans: [span(event)]
            }]
          }]
        }
      end

      # TS otlp.ts:83-159.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def span(event)
        start = event_millis(event) * 1_000_000
        finish = truthy?(event.duration) ? start + (event.duration * 1_000_000) : start
        {
          traceId: TraceContext.trace_id(session_id(event)),
          spanId: TraceContext.span_id(event.id),
          name: span_name(event),
          kind: SPAN_KIND_SERVER,
          startTimeUnixNano: start.to_s,
          endTimeUnixNano: finish.to_s,
          attributes: attributes(event).map { |key, value| {key: key, value: {stringValue: value}} },
          status: {code: event.is_error ? STATUS_ERROR : STATUS_OK}
        }
      end

      sig { params(event: UnredactedEvent).returns(String) }
      def span_name(event)
        truthy?(event.event_type) ? event.event_type : "mcp.event"
      end

      # String attributes in TS's order; empty ones are left out, like TS.
      sig { params(event: UnredactedEvent).returns(T::Hash[String, String]) }
      def attributes(event)
        attributes = {
          "source" => SOURCE,
          "mcp.event_type" => event.event_type,
          "mcp.session_id" => event.session_id,
          "mcp.project_id" => event.project_id,
          "mcp.resource_name" => event.resource_name,
          "mcp.user_intent" => event.user_intent,
          "mcp.actor_id" => event.identify_actor_given_id,
          "mcp.actor_name" => event.identify_actor_name,
          "mcp.client_name" => event.client_name,
          "mcp.client_version" => event.client_version
        }
        wire_tags(event)&.each { |key, value| attributes["agentcat.tag.#{key}"] = value }
        properties = wire_properties(event)
        attributes["agentcat.properties"] = properties.to_json if properties
        attributes.select { |_, value| truthy?(value) }
      end

      # Ruby only: the same span through your own OpenTelemetry tracer.
      sig { params(event: UnredactedEvent).void }
      def emit_through_tracer(event)
        start = Time.at(Rational(event_millis(event), 1000))
        span = T.unsafe(@tracer).start_span(span_name(event), kind: span_kind, attributes: attributes(event), start_timestamp: start)
        if event.is_error
          status = error_status
          status ? (span.status = status) : span.set_attribute("otel.status_code", "ERROR")
        end
        span.finish(end_timestamp: start + (event.duration / 1000.0))
      end

      sig { returns(T.untyped) }
      def span_kind
        OpenTelemetry::Trace::SpanKind::SERVER
      rescue NameError
        :server
      end

      sig { returns(T.untyped) }
      def error_status
        OpenTelemetry::Trace::Status.error
      rescue NameError
        nil
      end
    end
  end
end
