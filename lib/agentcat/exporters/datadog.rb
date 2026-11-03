# typed: true

module AgentCat
  module Exporters
    # Sends each event to Datadog as one log (logs intake v2) and a few metrics
    # (series v1), like TS's src/modules/exporters/datadog.ts. Plain Net::HTTP, no
    # extra gem.
    #
    #   AgentCat.track(server, project_id, AgentCat::Options.new(
    #     exporters: [AgentCat::Exporters::Datadog.new(api_key: ENV["DD_API_KEY"], site: "datadoghq.com", service: "my-mcp-server")]
    #   ))
    #
    # Keys (TS names in snake_case): api_key, site, service (all required, like TS)
    # and env. Ruby only: http_post.
    class Datadog < Base
      extend T::Sig

      # Hash-form keys, TS camelCase and Ruby snake_case, to initializer keywords.
      CONFIG_KEYS = {
        "api_key" => :api_key, "apiKey" => :api_key, "site" => :site, "service" => :service,
        "env" => :env, "http_post" => :http_post
      }.freeze

      sig { returns(T.nilable(String)) }
      attr_reader :logs_url, :metrics_url

      sig do
        params(
          api_key: T.nilable(String),
          site: T.nilable(String),
          service: T.nilable(String),
          env: T.nilable(String),
          http_post: T.untyped
        ).void
      end
      def initialize(api_key: nil, site: nil, service: nil, env: nil, http_post: nil)
        missing = {"api_key" => api_key, "site" => site, "service" => service}.select { |_, value| blank?(value) }.keys
        unless missing.empty?
          setup_failed!("Datadog exporter needs #{missing.join(", ")}")
          return
        end

        @api_key = T.must(api_key)
        @service = T.must(service)
        @env = env
        # TS datadog.ts:64-66: "https://datadoghq.eu/" and "datadoghq.eu" are the same site.
        host = T.must(site).sub(%r{\Ahttps?://}, "").sub(%r{/\z}, "")
        @logs_url = T.let("https://http-intake.logs.#{host}/api/v2/logs", T.nilable(String))
        @metrics_url = T.let("https://api.#{host}/api/v1/series", T.nilable(String))
        @http_post = resolve_http_post(http_post)
      end

      # Both requests go out even when one fails, like TS; a failure then raises so
      # Exporters.dispatch logs it.
      sig { params(event: UnredactedEvent).void }
      def export!(event)
        failures = T.let([], T::Array[StandardError])
        [[T.must(@logs_url), [log(event)]], [T.must(@metrics_url), {series: metrics(event)}]].each do |url, payload|
          post_json!("Datadog", url, headers, payload)
        rescue => e
          failures << e
        end
        raise T.must(failures.first) unless failures.empty?
      end

      private

      sig { returns(T::Hash[String, String]) }
      def headers
        {"DD-API-KEY" => @api_key, "Content-Type" => "application/json"}
      end

      sig { params(event: UnredactedEvent).returns(T::Array[String]) }
      def common_tags(event)
        tags = []
        tags << "env:#{@env}" if truthy?(@env)
        tags << "event_type:#{event.event_type.tr("/", ".")}" if truthy?(event.event_type)
        tags << "resource:#{event.resource_name}" if truthy?(event.resource_name)
        tags
      end

      # TS datadog.ts:126-189.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def log(event)
        tags = common_tags(event)
        tags << "error:true" if event.is_error
        tags << "source:#{SOURCE}"
        customer_tags = wire_tags(event)
        customer_tags&.each do |key, value|
          tags << "agentcat.#{key.downcase.gsub(/[[:space:]﻿:,]+/, "_")}:#{value.tr(",", "_")}"
        end

        log = {
          message: "#{truthy?(event.event_type) ? event.event_type : "unknown"} - #{truthy?(event.resource_name) ? event.resource_name : "unknown"}",
          service: @service,
          ddsource: SOURCE,
          ddtags: tags.join(","),
          timestamp: event_millis(event),
          status: event.is_error ? "error" : "info",
          dd: {trace_id: TraceContext.datadog_trace_id(session_id(event)), span_id: TraceContext.datadog_span_id(event.id)},
          mcp: {
            session_id: event.session_id,
            event_id: event.id,
            event_type: event.event_type,
            resource: event.resource_name,
            duration_ms: event.duration,
            user_intent: event.user_intent,
            actor_id: event.identify_actor_given_id,
            actor_name: event.identify_actor_name,
            client_name: event.client_name,
            client_version: event.client_version,
            server_name: event.server_name,
            server_version: event.server_version,
            is_error: event.is_error,
            error: event.error,
            tags: customer_tags,
            properties: wire_properties(event)
          }.compact
        }
        log[:error] = {message: event.error.to_json} if event.is_error && event.error
        log
      end

      # TS datadog.ts:191-233.
      sig { params(event: UnredactedEvent).returns(T::Array[T::Hash[Symbol, T.untyped]]) }
      def metrics(event)
        seconds = event_millis(event).div(1000)
        tags = ["service:#{@service}"] + common_tags(event)
        series = T.let([], T::Array[T::Hash[Symbol, T.untyped]])
        series << {metric: "mcp.events.count", type: "count", points: [[seconds, 1]], tags: tags}
        series << {metric: "mcp.event.duration", type: "gauge", points: [[seconds, event.duration]], tags: tags} if truthy?(event.duration)
        series << {metric: "mcp.errors.count", type: "count", points: [[seconds, 1]], tags: tags} if event.is_error
        series
      end
    end
  end
end
