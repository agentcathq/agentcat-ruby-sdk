# typed: true

module AgentCat
  module Exporters
    # Sends each event to PostHog's batch endpoint, like TS's
    # src/modules/exporters/posthog.ts: one capture event, a `$exception` event for an
    # error, and with enable_ai_tracing a `$ai_span` event for each tool call.
    #
    #   AgentCat.track(server, project_id, AgentCat::Options.new(
    #     exporters: [AgentCat::Exporters::PostHog.new(api_key: ENV["POSTHOG_PROJECT_API_KEY"])]
    #   ))
    #
    # Keys (TS names in snake_case): api_key (required), host (default
    # "https://us.i.posthog.com"; self-hosted and EU too) and enable_ai_tracing
    # (default false). Ruby only: http_post.
    class PostHog < Base
      extend T::Sig

      DEFAULT_HOST = "https://us.i.posthog.com"

      CONFIG_KEYS = {
        "api_key" => :api_key, "apiKey" => :api_key, "host" => :host,
        "enable_ai_tracing" => :enable_ai_tracing, "enableAITracing" => :enable_ai_tracing,
        "http_post" => :http_post
      }.freeze

      # TS posthog.ts:327-343.
      EVENT_NAMES = {
        "mcp:tools/call" => "mcp_tool_call",
        "mcp:tools/list" => "mcp_tools_list",
        "mcp:initialize" => "mcp_initialize",
        "mcp:resources/read" => "mcp_resource_read",
        "mcp:resources/list" => "mcp_resources_list",
        "mcp:prompts/get" => "mcp_prompt_get",
        "mcp:prompts/list" => "mcp_prompts_list"
      }.freeze

      sig { returns(T.nilable(String)) }
      attr_reader :batch_url

      sig do
        params(
          api_key: T.nilable(String),
          host: T.nilable(String),
          enable_ai_tracing: T::Boolean,
          http_post: T.untyped
        ).void
      end
      def initialize(api_key: nil, host: nil, enable_ai_tracing: false, http_post: nil)
        if blank?(api_key)
          setup_failed!("PostHog exporter needs an api_key (project API key)")
          return
        end

        @api_key = T.must(api_key)
        @enable_ai_tracing = enable_ai_tracing
        @batch_url = T.let("#{base_url(host)}/batch", T.nilable(String))
        @http_post = resolve_http_post(http_post)
      end

      sig { params(event: UnredactedEvent).void }
      def export!(event)
        batch = [capture_event(event)]
        batch << exception_event(event) if event.is_error && event.error
        batch << ai_span_event(event) if @enable_ai_tracing && event.event_type == TOOLS_CALL
        post_json!("PostHog", T.must(@batch_url), {"Content-Type" => "application/json"}, {api_key: @api_key, batch: batch})
      end

      private

      # TS posthog.ts:101 takes host as a URL, scheme included, and drops one trailing
      # slash. Ruby only: a bare host ("eu.i.posthog.com")
      # gets https://, instead of making a URL with no scheme.
      sig { params(host: T.nilable(String)).returns(String) }
      def base_url(host)
        url = blank?(host) ? DEFAULT_HOST : T.must(host)
        url = "https://#{url}" unless %r{\A[a-z][a-z0-9+.-]*://}i.match?(url)
        url.sub(%r{/\z}, "")
      end

      sig { params(event: UnredactedEvent).returns(String) }
      def distinct_id(event)
        [event.identify_actor_given_id, event.session_id].find { |id| truthy?(id) } || "anonymous"
      end

      sig { params(event: UnredactedEvent, name: String, properties: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
      def capture(event, name, properties)
        {event: name, distinct_id: distinct_id(event), properties: properties, timestamp: iso_millis(event_millis(event)), type: "capture"}
      end

      sig { params(event: UnredactedEvent, properties: T::Hash[String, T.untyped]).void }
      def add_resource(event, properties)
        return unless truthy?(event.resource_name)

        properties["resource_name"] = event.resource_name
        properties["tool_name"] = event.resource_name if event.event_type == TOOLS_CALL
      end

      sig { params(properties: T::Hash[String, T.untyped], values: T::Hash[String, T.untyped]).void }
      def add_truthy(properties, values)
        values.each { |key, value| properties[key] = value if truthy?(value) }
      end

      # Customer tags, then customer properties, spread on top: they can override
      # AgentCat's own keys, like TS.
      sig { params(event: UnredactedEvent, properties: T::Hash[String, T.untyped]).void }
      def spread_customer_data(event, properties)
        properties.merge!(wire_tags(event) || {})
        properties.merge!(wire_properties(event) || {})
      end

      # TS posthog.ts:156-225.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def capture_event(event)
        properties = {"source" => SOURCE}
        properties["$session_id"] = TraceContext.uuid_v7(T.must(session_id(event))) if session_id(event)
        add_resource(event, properties)
        properties["duration_ms"] = event.duration
        add_truthy(properties, {
          "server_name" => event.server_name, "server_version" => event.server_version,
          "client_name" => event.client_name, "client_version" => event.client_version,
          "project_id" => event.project_id, "user_intent" => event.user_intent
        })
        properties["is_error"] = event.is_error
        properties["parameters"] = event.parameters
        properties["response"] = event.response unless event.response.nil?

        set = {}
        set["name"] = event.identify_actor_name if truthy?(event.identify_actor_name)
        set.merge!(event.identify_data.to_h) if event.identify_data
        properties["$set"] = set unless set.empty?

        spread_customer_data(event, properties)
        capture(event, event_name(event.event_type), properties)
      end

      # TS posthog.ts:227-269.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def exception_event(event)
        properties = {"$exception_source" => "backend"}
        properties["$session_id"] = TraceContext.uuid_v7(T.must(session_id(event))) if session_id(event)
        error = event.error || {}
        add_truthy(properties, {
          "$exception_message" => error["message"], "$exception_type" => error["type"],
          "$exception_stacktrace" => error["stack"]
        })
        add_resource(event, properties)
        add_truthy(properties, {
          "server_name" => event.server_name, "server_version" => event.server_version,
          "client_name" => event.client_name, "client_version" => event.client_version
        })
        capture(event, "$exception", properties)
      end

      # TS posthog.ts:271-325.
      sig { params(event: UnredactedEvent).returns(T::Hash[Symbol, T.untyped]) }
      def ai_span_event(event)
        session = session_id(event)
        properties = {
          "$ai_trace_id" => TraceContext.uuid_v7(session || event.id),
          "$ai_span_id" => TraceContext.uuid_v7(event.id),
          "$ai_span_name" => truthy?(event.resource_name) ? event.resource_name : "unknown_tool",
          "$ai_is_error" => event.is_error,
          "source" => SOURCE
        }
        if session
          properties["$ai_session_id"] = "agentcat_#{session}"
          properties["$session_id"] = TraceContext.uuid_v7(session)
        end
        properties["$ai_latency"] = js_number(event.duration / 1000.0)
        properties["$ai_error"] = event.error if event.is_error && event.error
        properties["$ai_input_state"] = event.parameters
        properties["$ai_output_state"] = event.response unless event.response.nil?
        add_truthy(properties, {"server_name" => event.server_name, "client_name" => event.client_name})
        spread_customer_data(event, properties)
        capture(event, "$ai_span", properties)
      end

      sig { params(event_type: String).returns(String) }
      def event_name(event_type)
        EVENT_NAMES[event_type] || "mcp_#{event_type.sub(/\Amcp:/, "").tr("/", "_")}"
      end
    end
  end
end
