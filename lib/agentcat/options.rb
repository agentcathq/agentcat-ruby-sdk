# typed: true

require "uri"
require_relative "hooks"
require_relative "log"

module AgentCat
  # Per-server configuration passed to `AgentCat.track`.
  #
  # * `enable_agent_tracking` — also inject `agent_id` and report it as the event actor.
  # * `enable_report_missing` — on by default. Set `false` to skip registering
  #   `get_more_tools` (matches Python/Go's `enable_report_missing`/`DisableReportMissing`).
  #   A host that already defines its own keeps it either way.
  # * `resolve_session_id` — `(tool_call) -> String | nil`. Set this and the
  #   host owns session identity: no `session_id` in the schema, and whatever correlation id
  #   you return gets derived into a `ses_` KSUID (SHA-256, never reported verbatim) the same
  #   way the Go/TypeScript SDKs do it.
  # * `stateless` — deprecated, logs a warning if set. No per-connection session; grouping
  #   falls back to identified user + client + a 30-minute window, which needs `identify` to
  #   work at all. MCP is stateless by default now, so this doesn't do anything the rest of
  #   the SDK doesn't already handle — use `resolve_session_id` or `identify` instead.
  # * `identify` — `(tool_call) -> UserIdentity | nil`, run on every call.
  #   `user_id` becomes the event's actor.
  # * `redact_sensitive_information` — `(string) -> String`, applied to every string leaving
  #   the process. Runs after `redact_event`, on top of whatever the server already redacts.
  # * `redact_event` — `(UnredactedEvent) -> UnredactedEvent | nil`. Mutate and return the
  #   event, or return `nil` to drop it. Runs before `redact_sensitive_information`, so it
  #   sees raw values. Don't build a fresh event to return — the result replaces the whole
  #   thing, and anything you didn't set is gone.
  # * `event_tags` — `(tool_call) -> Hash[String, String]`, filterable tags.
  # * `event_properties` — `(tool_call) -> Hash`, arbitrary metadata merged
  #   into every event.
  #
  #   `tool_call` is a frozen `AgentCat::ToolCall` (tool name, arguments, `_meta`, HTTP
  #   headers, client name and version, protocol version, `Mcp-Session-Id`, the Rack env
  #   and the server context), built before any hook runs. Changing its arguments raises
  #   `FrozenError` and never reaches the tool or the event. Earlier releases passed these four hooks
  #   `(arguments, server_context)`; a hook that still takes two arguments logs one
  #   WARN line at `track`.
  # * `hook_timeout` — wall-clock cap per hook, default 1s, max 5s. Go/Python/TS hardcode
  #   this; Ruby exposes it so you can tune it without a code change.
  # * `client` — anything with `post_event(event)`. Defaults to `AgentCat::Client`.
  # * `queue_size` — events kept before the oldest gets dropped (default 10,000, same as
  #   the reference SDKs). Applies to the process-wide queue the first time it's used.
  # * `max_retries` — retries past the first attempt (default 3), exponential backoff.
  #   `retry_base_delay` is the first backoff in seconds (default 1), doubling each time
  #   (~1s, 2s, 4s) plus jitter.
  # * `request_timeout` — per-attempt HTTP timeout for the default client (default 10s; the
  #   connect timeout is fixed at 1s). First `track` call wins, same as the queue.
  # * `api_base_url` — overrides the default client's endpoint (scheme + host, optional
  #   port/path prefix), for pointing a non-default environment at your own stage/test
  #   API without exporting AGENTCAT_API_URL. Takes precedence over that env var when
  #   both are set. First `track` call wins, same as `request_timeout`. No effect with a
  #   custom `client:`.
  # * `exporters` — objects responding to `#export(event)` or `#call`, or TS's hash form
  #   (`{type: "datadog", api_key: "...", site: "...", service: "..."}`, see
  #   `Exporters.resolve`). Each one runs asynchronously; one failing doesn't touch the
  #   others or the tool call. Works fine with `project_id: nil` if you just want telemetry
  #   forwarded somewhere. Otlp/Datadog/Sentry/PostHog ship built in — subclass
  #   `Exporters::Base` for anything else. An entry that is neither logs one line and is
  #   skipped.
  # * `disable_diagnostics` — opt out of the diagnostics beacon (see `Diagnostics`). On by
  #   default; `DISABLE_DIAGNOSTICS` and the test-env auto-disable still apply on top.
  #
  # A bad value never raises: a hook that doesn't respond to `#call` is dropped,
  # and a number out of range or a malformed `api_base_url` falls back to the default.
  # Each logs one WARN line. A value of the wrong Ruby type (a String `queue_size`) still
  # fails fast in the Sorbet sig, like PHP's own type errors.
  class Options
    extend T::Sig

    Hook = T.type_alias { T.untyped }
    StringHook = T.type_alias { T.untyped }
    EventHook = T.type_alias { T.untyped }

    DEFAULT_HOOK_TIMEOUT = 1
    MAX_HOOK_TIMEOUT = 5
    DEFAULT_QUEUE_SIZE = 10_000
    DEFAULT_MAX_RETRIES = 3
    DEFAULT_RETRY_BASE_DELAY = 1.0
    DEFAULT_REQUEST_TIMEOUT = 10

    sig { returns(T::Boolean) }
    attr_accessor :enable_agent_tracking

    # Off: no session_id/agent_id injected, no mint-back, no events published (tool calls
    # or custom events on this server). `context` and `get_more_tools` keep following
    # their own flags. Same as `enableTracing` (TS/Python) / `DisableTracing` (Go).
    sig { returns(T::Boolean) }
    attr_accessor :enable_tracing

    # Off: no `context` parameter injected into your tools. `get_more_tools` keeps its own.
    sig { returns(T::Boolean) }
    attr_accessor :enable_tool_call_context

    # Replaces the default description of the injected `context` parameter, e.g. to tell
    # agents what kind of intent matters for your domain. nil or blank means the default.
    sig { returns(T.nilable(String)) }
    attr_accessor :custom_context_description

    sig { returns(T::Boolean) }
    attr_accessor :enable_report_missing

    sig { returns(T::Array[T.untyped]) }
    attr_accessor :exporters

    sig { returns(T::Boolean) }
    attr_accessor :disable_diagnostics

    sig { returns(T.nilable(Hook)) }
    attr_accessor :resolve_session_id

    sig { returns(T::Boolean) }
    attr_accessor :stateless

    sig { returns(T.nilable(Hook)) }
    attr_accessor :identify

    sig { returns(T.nilable(StringHook)) }
    attr_accessor :redact_sensitive_information

    sig { returns(T.nilable(EventHook)) }
    attr_accessor :redact_event

    sig { returns(T.nilable(Hook)) }
    attr_accessor :event_tags

    sig { returns(T.nilable(Hook)) }
    attr_accessor :event_properties

    sig { returns(Float) }
    attr_reader :hook_timeout

    sig { returns(Integer) }
    attr_reader :queue_size

    sig { returns(Integer) }
    attr_reader :max_retries

    sig { returns(Float) }
    attr_reader :retry_base_delay

    sig { returns(Float) }
    attr_reader :request_timeout

    sig { returns(T.nilable(String)) }
    attr_reader :api_base_url

    sig { params(client: T.untyped).void }
    attr_writer :client

    sig do
      params(
        enable_agent_tracking: T::Boolean,
        enable_tracing: T::Boolean,
        enable_tool_call_context: T::Boolean,
        custom_context_description: T.nilable(String),
        enable_report_missing: T::Boolean,
        exporters: T::Array[T.untyped],
        disable_diagnostics: T::Boolean,
        resolve_session_id: T.nilable(Hook),
        stateless: T::Boolean,
        identify: T.nilable(Hook),
        redact_sensitive_information: T.nilable(StringHook),
        redact_event: T.nilable(EventHook),
        event_tags: T.nilable(Hook),
        event_properties: T.nilable(Hook),
        hook_timeout: Numeric,
        client: T.untyped,
        queue_size: Integer,
        max_retries: Integer,
        retry_base_delay: Numeric,
        request_timeout: Numeric,
        api_base_url: T.nilable(String)
      ).void
    end
    def initialize(
      enable_agent_tracking: false,
      enable_tracing: true,
      enable_tool_call_context: true,
      custom_context_description: nil,
      enable_report_missing: true,
      exporters: [],
      disable_diagnostics: false,
      resolve_session_id: nil,
      stateless: false,
      identify: nil,
      redact_sensitive_information: nil,
      redact_event: nil,
      event_tags: nil,
      event_properties: nil,
      hook_timeout: DEFAULT_HOOK_TIMEOUT,
      client: nil,
      queue_size: DEFAULT_QUEUE_SIZE,
      max_retries: DEFAULT_MAX_RETRIES,
      retry_base_delay: DEFAULT_RETRY_BASE_DELAY,
      request_timeout: DEFAULT_REQUEST_TIMEOUT,
      api_base_url: nil
    )
      warn_if_stateless_deprecated!(stateless)

      @enable_agent_tracking = enable_agent_tracking
      @enable_tracing = enable_tracing
      @enable_tool_call_context = enable_tool_call_context
      @custom_context_description = custom_context_description
      @enable_report_missing = enable_report_missing
      @exporters = Exporters.resolve(exporters)
      @disable_diagnostics = disable_diagnostics
      @resolve_session_id = callable_or_nil(resolve_session_id, "resolve_session_id")
      @stateless = stateless
      @identify = callable_or_nil(identify, "identify")
      @redact_sensitive_information = callable_or_nil(redact_sensitive_information, "redact_sensitive_information")
      @redact_event = callable_or_nil(redact_event, "redact_event")
      @event_tags = callable_or_nil(event_tags, "event_tags")
      @event_properties = callable_or_nil(event_properties, "event_properties")
      @hook_timeout = [positive_float_or_default(hook_timeout, "hook_timeout", DEFAULT_HOOK_TIMEOUT), MAX_HOOK_TIMEOUT.to_f].min
      @client = client
      @queue_size = int_or_default(queue_size, "queue_size", DEFAULT_QUEUE_SIZE, min: 1)
      @max_retries = int_or_default(max_retries, "max_retries", DEFAULT_MAX_RETRIES, min: 0)
      @retry_base_delay = positive_float_or_default(retry_base_delay, "retry_base_delay", DEFAULT_RETRY_BASE_DELAY)
      @request_timeout = positive_float_or_default(request_timeout, "request_timeout", DEFAULT_REQUEST_TIMEOUT)
      @api_base_url = http_url_or_nil(api_base_url)
    end

    sig { returns(T.untyped) }
    def client
      @client || AgentCat::Client
    end

    sig { returns(T::Boolean) }
    def default_client?
      @client.nil?
    end

    sig { returns(String) }
    def context_description
      custom = custom_context_description
      (custom.nil? || custom.strip.empty?) ? Schema::CONTEXT_DESCRIPTION : custom
    end

    sig { returns(T::Boolean) }
    def host_managed_sessions?
      !resolve_session_id.nil?
    end

    sig { returns(T::Boolean) }
    def stateless?
      !!stateless
    end

    private

    sig { params(stateless: T::Boolean).void }
    def warn_if_stateless_deprecated!(stateless)
      return unless stateless

      Log.warn(
        "Options#stateless is deprecated and will be removed in a future release. MCP " \
        "itself is stateless by default now (the 2026-07-28 spec), so every call already " \
        "resolves session identity per request regardless of this option. Use " \
        "resolve_session_id for host-managed sessions, or identify alone to attribute " \
        "actors with no session concept at all."
      )
    end

    sig { params(message: String).void }
    def warn_bad_value(message)
      # Rate-limited: an app that builds its Options per request logs this once a minute.
      Log.warn("Options##{message}")
    end

    sig { params(hook: T.untyped, name: String).returns(T.untyped) }
    def callable_or_nil(hook, name)
      return hook if hook.nil? || hook.respond_to?(:call)

      warn_bad_value("#{name} must respond to #call, got #{hook.class}; the hook is ignored")
      nil
    end

    sig { params(value: Integer, name: String, default: Integer, min: Integer).returns(Integer) }
    def int_or_default(value, name, default, min:)
      return value if value >= min

      warn_bad_value("#{name} must be #{(min == 1) ? "at least 1" : "#{min} or more"}, got #{value}; using the default #{default}")
      default
    end

    # NaN fails `> 0` too.
    sig { params(value: Numeric, name: String, default: Numeric).returns(Float) }
    def positive_float_or_default(value, name, default)
      float = value.to_f
      return float if float > 0

      warn_bad_value("#{name} must be a positive number, got #{value.inspect}; using the default #{default.to_f}")
      default.to_f
    end

    sig { params(url: T.nilable(String)).returns(T.nilable(String)) }
    def http_url_or_nil(url)
      return nil if url.nil?

      uri = begin
        URI.parse(url)
      rescue URI::InvalidURIError
        nil
      end
      return url if uri.is_a?(URI::HTTP) && !uri.host.to_s.empty?

      warn_bad_value("api_base_url must be an absolute http(s) URL, got #{url.inspect}; using the default endpoint")
      nil
    end
  end
end
