# typed: strict

require "uri"
require "agentcat-api"
require_relative "diagnostics"

module AgentCatApi
  # `PublishEventRequest#event_type=` validates against the OpenAPI spec's enum, which
  # predates `agentcat:custom` (see `AgentCat::Client::CUSTOM_EVENT_TYPE`) — the backend
  # has accepted that value since the TypeScript SDK's 2.0 release, but every generated
  # client (Ruby, Python, TS's own type alias) still ships the stale list, because
  # they're all generated from the same spec snapshot. Left alone, every custom event
  # would fail construction right here and vanish into `Client#post_event`'s rescue.
  #
  # Same fix the Python SDK ships (`agentcat/types.py`'s `Event#event_type_validate_enum`
  # override) — don't remove this expecting a future `agentcat-api` bump to carry it;
  # regenerating from the same stale spec would silently reintroduce the rejection.
  # `test/test_client.rb`'s custom-event-type test is the tripwire.
  class PublishEventRequest
    extend T::Sig

    alias_method :_generated_event_type=, :event_type=

    sig { params(event_type: T.untyped).void }
    def event_type=(event_type)
      if event_type == AgentCat::Client::CUSTOM_EVENT_TYPE
        @event_type = T.let(event_type, T.nilable(String))
      else
        self._generated_event_type = event_type
      end
    end
  end

  # Every generated model's `_to_hash` calls `value.compact` on arrays before it maps
  # them, so a payload array `[1, nil, 2]` would go out as `[1, 2]`, and the event would not
  # say what the tool got or returned. Same reasoning as the `event_type=` reopening
  # above - a regenerated `agentcat-api` would bring the `compact` back, so the fix
  # lives here. `test/test_client.rb`'s nil-element tests are the tripwire.
  module KeepNilArrayElements
    extend T::Sig

    sig { params(value: T.untyped).returns(T.untyped) }
    def _to_hash(value)
      return value.map { |element| _to_hash(element) } if value.is_a?(Array)

      super
    end
  end

  constants.each do |name|
    klass = const_get(name)
    next unless klass.is_a?(Class) && klass.method_defined?(:_to_hash)

    klass.prepend(KeepNilArrayElements) unless klass.ancestors.include?(KeepNilArrayElements)
  end
end

module AgentCat
  # Thin wrapper around the generated agentcat-api client. Runs on the event queue's
  # worker thread, never the caller's (see EventQueue, Delivery).
  #
  # AGENTCAT_API_URL is just the base (scheme, host, optional port/path prefix) — the
  # generated client appends the events path itself.
  class Client
    DEFAULT_API_URL = "https://api.agentcat.com"
    ENV_API_URL = "AGENTCAT_API_URL"
    ENV_API_KEY = "AGENTCAT_API_KEY"
    # See the `AgentCatApi::PublishEventRequest` reopening above this class.
    CUSTOM_EVENT_TYPE = "agentcat:custom"
    # Without these a hung connection stalls the worker thread forever and the queue
    # just stops draining. 10s read / 1s open, matching the reference SDKs;
    # Options#request_timeout overrides the read side.
    OPEN_TIMEOUT_SECONDS = 1
    DEFAULT_READ_TIMEOUT_SECONDS = 10
    EVENT_FIELDS = T.let(AgentCatApi::PublishEventRequest.attribute_map.keys.freeze, T::Array[Symbol])

    # First `track` call wins — this is process-wide, same as the queue and exporters.
    @configured_read_timeout = T.let(nil, T.nilable(Float))
    @configured_api_url = T.let(nil, T.nilable(String))

    class << self
      extend T::Sig

      # `Options#api_base_url` takes precedence over AGENTCAT_API_URL; first `track`
      # call wins, same as the read timeout.
      sig { params(url: String).void }
      def configure_base_url(url)
        @configured_api_url ||= url
      end

      sig { returns(String) }
      def api_url
        @configured_api_url || env_api_url
      end

      sig { returns(T.nilable(String)) }
      def api_key
        value = ENV[ENV_API_KEY]
        (value.nil? || value.empty?) ? nil : value
      end

      sig { params(seconds: Numeric).void }
      def configure_timeout(seconds)
        @configured_read_timeout ||= seconds.to_f
      end

      sig { returns(Float) }
      def read_timeout_seconds
        @configured_read_timeout || DEFAULT_READ_TIMEOUT_SECONDS.to_f
      end

      sig { void }
      def reset_timeout!
        @configured_read_timeout = nil
      end

      sig { void }
      def reset_base_url!
        @configured_api_url = nil
      end

      # Publishes one event. Never raises; returns the API response or nil on failure.
      sig { params(event: T::Hash[Symbol, T.untyped]).returns(T.nilable(AgentCatApi::EventAcceptedResponse)).checked(:tests) }
      def post_event(event)
        attributes = EVENT_FIELDS.each_with_object({}) { |field, acc| acc[field] = event[field] if event.key?(field) }
        request = AgentCatApi::PublishEventRequest.new(attributes)
        headers = {}
        headers["Authorization"] = "Bearer #{api_key}" if api_key

        # Authorization is set explicitly above; disabling the generated auth scheme avoids a nil header when no key is configured.
        events_api.publish_event(publish_event_request: request, header_params: headers, debug_auth_names: [])
      rescue => e
        # The API error's message carries the response body: debug only.
        code = e.is_a?(AgentCatApi::ApiError) ? e.code : nil
        status = code ? " (HTTP #{code})" : ""
        AgentCat::Log.error("failed to publish event to AgentCat: #{e.class}#{status}")
        AgentCat.logger.debug { "failed to publish event: #{e.class}: #{e.message}" }
        nil
      end

      sig { returns(AgentCatApi::Configuration) }
      def configuration
        uri = URI.parse(api_url)
        AgentCatApi::Configuration.new.tap do |config|
          config.scheme = uri.scheme
          config.host = (uri.port == uri.default_port) ? uri.host : "#{uri.host}:#{uri.port}"
          config.base_path = uri.path.to_s.sub(%r{/+\z}, "")
          config.ignore_operation_servers = true
          config.timeout = read_timeout_seconds
          config.configure_faraday_connection do |conn|
            conn.options.open_timeout = OPEN_TIMEOUT_SECONDS
            conn.options.timeout = read_timeout_seconds
          end
        end
      end

      private

      sig { returns(String) }
      def env_api_url
        value = ENV[ENV_API_URL]
        (value.nil? || value.empty?) ? DEFAULT_API_URL : value
      end

      sig { returns(AgentCatApi::EventsApi) }
      def events_api
        AgentCatApi::EventsApi.new(AgentCatApi::ApiClient.new(configuration))
      end
    end
  end
end
