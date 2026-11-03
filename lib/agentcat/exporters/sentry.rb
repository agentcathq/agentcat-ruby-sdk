# typed: true

require "json"
require "time"

module AgentCat
  module Exporters
    # Sends events to Sentry's envelope endpoint, built from your DSN, like TS's
    # src/modules/exporters/sentry.ts: a log for every event, a transaction for every
    # event with enable_tracing, and an error event (an Issue) for every failed call.
    # It uses only its own dsn:, never the sentry-ruby gem or your app's Sentry.init.
    #
    #   AgentCat.track(server, project_id, AgentCat::Options.new(
    #     exporters: [AgentCat::Exporters::Sentry.new(dsn: ENV["SENTRY_DSN"], environment: "production")]
    #   ))
    #
    # Keys (TS names in snake_case): dsn (required), environment, release and
    # enable_tracing (default false). Like TS, environment and release go out as tags.
    # Ruby only: http_post.
    class Sentry < Base
      extend T::Sig

      CONFIG_KEYS = {
        "dsn" => :dsn, "environment" => :environment, "release" => :release,
        "enable_tracing" => :enable_tracing, "enableTracing" => :enable_tracing,
        "http_post" => :http_post
      }.freeze

      # protocol://public_key@host[:port][/path]/project_id, TS sentry.ts:350.
      DSN_PATTERN = %r{\A(https?)://([a-f0-9]+)@([\w.-]+)(:\d+)?(/.*)?/(\d+)\z}
      # TS sentry.ts:343, word for word: the client name is TS's, not a Ruby one.
      AUTH_HEADER = "Sentry sentry_version=7, sentry_client=agentcat/1.0.0, sentry_key=%s"
      CONTENT_TYPE = "application/x-sentry-envelope"

      sig { returns(T.nilable(String)) }
      attr_reader :endpoint

      sig do
        params(
          dsn: T.nilable(String),
          environment: T.nilable(String),
          release: T.nilable(String),
          enable_tracing: T::Boolean,
          http_post: T.untyped
        ).void
      end
      def initialize(dsn: nil, environment: nil, release: nil, enable_tracing: false, http_post: nil)
        if blank?(dsn)
          setup_failed!("Sentry exporter needs a dsn")
          return
        end
        match = DSN_PATTERN.match(T.must(dsn))
        if match.nil?
          # The DSN itself stays out of the line: it carries the project's key.
          setup_failed!("Sentry exporter got an invalid dsn (expected https://<public_key>@<host>/<project_id>)")
          return
        end

        @endpoint = T.let("#{match[1]}://#{match[3]}#{match[4]}#{match[5]}/api/#{match[6]}/envelope/", T.nilable(String))
        @headers = {"X-Sentry-Auth" => format(AUTH_HEADER, match[2]), "Content-Type" => CONTENT_TYPE}
        @environment = environment
        @release = release
        @enable_tracing = enable_tracing
        @http_post = resolve_http_post(http_post)
      end

      # Every envelope goes out even when one fails, like TS; a failure then raises so
      # Exporters.dispatch logs it.
      sig { params(event: UnredactedEvent).void }
      def export!(event)
        envelopes = [log_envelope(event)]
        transaction = transaction(event) if @enable_tracing
        envelopes << envelope(transaction[:event_id], {type: "transaction"}, transaction) if transaction
        if event.is_error
          error_event = error_event(event, transaction)
          envelopes << envelope(error_event[:event_id], {type: "event", content_type: "application/json"}, error_event)
        end

        failures = T.let([], T::Array[StandardError])
        envelopes.each do |body|
          post!("Sentry", T.must(@endpoint), @headers, body)
        rescue => e
          failures << e
        end
        raise T.must(failures.first) unless failures.empty?
      end

      private

      sig { params(event_id: String, item_header: T::Hash[Symbol, T.untyped], item: T.untyped).returns(String) }
      def envelope(event_id, item_header, item)
        [{event_id: event_id, sent_at: Time.now.utc.iso8601(3)}.to_json, item_header.to_json, item.to_json].join("\n")
      end

      sig { params(event: UnredactedEvent).returns(Numeric) }
      def seconds(event)
        js_number(event_millis(event) / 1000.0)
      end

      # TS sentry.ts:456-480 and 539-566. The log envelope alone ends in a newline.
      sig { params(event: UnredactedEvent).returns(String) }
      def log_envelope(event)
        event_id = TraceContext.span_id(event.id) * 2
        type = truthy?(event.event_type) ? event.event_type : "event"
        log = {
          timestamp: seconds(event),
          trace_id: TraceContext.trace_id(session_id(event)),
          event_id: event_id,
          level: event.is_error ? "error" : "info",
          body: truthy?(event.resource_name) ? "MCP #{type}: #{event.resource_name}" : "MCP #{type}",
          attributes: log_attributes(event)
        }
        item_header = {type: "log", item_count: 1, content_type: "application/vnd.sentry.items.log+json"}
        envelope(event_id, item_header, {items: [log]}) + "\n"
      end

      # TS sentry.ts:482-537.
      sig { params(event: UnredactedEvent).returns(T::Hash[String, T.untyped]) }
      def log_attributes(event)
        attributes = {}
        {
          "eventType" => event.event_type, "resourceName" => event.resource_name,
          "serverName" => event.server_name, "clientName" => event.client_name,
          "sessionId" => event.session_id, "projectId" => event.project_id
        }.each { |key, value| attributes[key] = {value: value, type: "string"} if truthy?(value) }
        attributes["duration_ms"] = {value: event.duration, type: "double"}
        {
          "actorId" => event.identify_actor_given_id, "actorName" => event.identify_actor_name,
          "userIntent" => event.user_intent, "serverVersion" => event.server_version,
          "clientVersion" => event.client_version
        }.each { |key, value| attributes[key] = {value: value, type: "string"} if truthy?(value) }
        attributes["isError"] = {value: event.is_error, type: "boolean"}
        attributes
      end

      sig { params(event: UnredactedEvent).returns(String) }
      def transaction_name(event)
        if truthy?(event.resource_name)
          "#{truthy?(event.event_type) ? event.event_type : "mcp"} - #{event.resource_name}"
        else
          truthy?(event.event_type) ? event.event_type : "mcp.event"
        end
      end

      sig { params(event: UnredactedEvent).returns(String) }
      def op(event)
        truthy?(event.event_type) ? event.event_type : "mcp.event"
      end

      # TS sentry.ts:568-603. The event time is the end of the span.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def transaction(event)
        finish = seconds(event)
        start = truthy?(event.duration) ? js_number(finish - (event.duration / 1000.0)) : finish
        trace = {
          trace_id: TraceContext.trace_id(session_id(event)),
          span_id: TraceContext.span_id(event.id),
          op: op(event),
          status: event.is_error ? "internal_error" : "ok"
        }
        {
          type: "transaction",
          event_id: TraceContext.span_id(event.id) + TraceContext.span_id,
          timestamp: finish,
          start_timestamp: start,
          transaction: transaction_name(event),
          contexts: contexts(event, trace),
          tags: tags(event),
          extra: extra(event)
        }
      end

      # TS sentry.ts:659-735.
      sig { params(event: UnredactedEvent, transaction: T.nilable(T::Hash[Symbol, T.untyped])).returns(T::Hash[Symbol, T.untyped]) }
      def error_event(event, transaction)
        message = "Unknown error"
        type = "ToolCallError"
        if (error = event.error)
          message = error.key?("message") ? error["message"].to_s : error.to_json
          type = error["type"].to_s if error.key?("type")
        end
        trace = {
          trace_id: transaction ? transaction[:contexts][:trace][:trace_id] : TraceContext.trace_id(session_id(event)),
          span_id: TraceContext.span_id(event.id),
          parent_span_id: transaction&.dig(:contexts, :trace, :span_id),
          op: transaction ? transaction[:contexts][:trace][:op] : op(event)
        }.compact
        mcp = {
          resource_name: event.resource_name, session_id: event.session_id,
          event_type: event.event_type, user_intent: event.user_intent
        }.compact
        {
          type: "event",
          event_id: TraceContext.span_id(event.id) + TraceContext.span_id,
          timestamp: transaction ? transaction[:timestamp] : seconds(event),
          level: "error",
          exception: {values: [{type: type, value: message, mechanism: {type: "mcp_tool_call", handled: false}}]},
          contexts: contexts(event, trace).merge(mcp: mcp),
          tags: tags(event),
          extra: extra(event),
          transaction: transaction ? transaction[:transaction] : transaction_name(event)
        }
      end

      # TS sentry.ts:605-626.
      sig { params(event: UnredactedEvent).returns(T::Hash[String, String]) }
      def tags(event)
        tags = {"source" => SOURCE}
        {
          "environment" => @environment, "release" => @release, "event_type" => event.event_type,
          "resource" => event.resource_name, "server_name" => event.server_name,
          "client_name" => event.client_name, "actor_id" => event.identify_actor_given_id
        }.each { |key, value| tags[key] = value if truthy?(value) }
        wire_tags(event)&.each { |key, value| tags["agentcat.#{key}"] = value }
        tags
      end

      # TS sentry.ts:628-641.
      sig { params(event: UnredactedEvent).returns(T::Hash[String, T.untyped]) }
      def extra(event)
        extra = {}
        {
          "session_id" => event.session_id, "project_id" => event.project_id,
          "user_intent" => event.user_intent, "actor_name" => event.identify_actor_name,
          "server_version" => event.server_version, "client_version" => event.client_version
        }.each { |key, value| extra[key] = value if truthy?(value) }
        extra["duration_ms"] = event.duration
        extra["error"] = event.error if event.error
        extra
      end

      # TS sentry.ts:643-657.
      sig { params(event: UnredactedEvent, trace: T::Hash[Symbol, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def contexts(event, trace)
        contexts = {trace: trace}
        properties = wire_properties(event)
        contexts[:agentcat] = properties if properties
        contexts
      end
    end
  end
end
