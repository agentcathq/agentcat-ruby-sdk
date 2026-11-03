# typed: true

require_relative "private_members"

module AgentCat
  # The per-request HTTP metadata the published event carries under
  # `parameters.extra` — the incoming request's headers and full URL, shaped as
  # `{requestInfo: {headers: {...}, url: "..."}}` to match the TypeScript v1 and
  # Python SDKs (`event.parameters.extra.requestInfo`).
  #
  # Why this exists: AgentCat reads client-identifying headers (User-Agent and
  # friends) to tell which agent harness made a call — "Claude Code", "Codex",
  # a bare Cursor, a browser — including on stateless HTTP servers where the
  # client never declared itself in `_meta`. The reference SDKs get the headers
  # for free because their MCP frameworks hand the request handler the transport
  # request; the `mcp` gem does not, so `Server#handle` and `server_context`
  # never see them. The only seam is the transport's own Rack entry point, so
  # `TransportHook` (below) captures the env there and `capture`/`restore` make
  # it ambient for exactly the duration of that request.
  #
  # `headers_from_env` mirrors Rack's own env->header rules (`HTTP_*` plus
  # `CONTENT_TYPE`/`CONTENT_LENGTH`), so a Rack server's headers come out the same
  # way every other Rack consumer reads them. Names are lower case and each value is
  # one string: repeated values are joined with ", ", the way a web server joins
  # repeated request headers.
  #
  # stdio has no request to read, so nothing is captured and the event's `extra`
  # has no `requestInfo` — again matching the reference SDKs, which only populate
  # `requestInfo` on HTTP transports.
  module RequestContext
    # Thread#[] is fiber-local, so a request handled on its own fiber (Falcon,
    # async Puma) can never read another fiber's headers.
    KEY = :agentcat_request_extra
    # The Rack env of the same request, for `ToolCall#request`.
    ENV_KEY = :agentcat_request_env

    # Guards the one-time class patch. Module-level (its own singleton would be the
    # wrong lock to reason about).
    INSTALL_MUTEX = T.let(Mutex.new, Mutex)

    class << self
      extend T::Sig

      # Prepends `TransportHook` to the streamable HTTP transport class. Idempotent
      # and process-wide, with a fast path once it has succeeded. Called from
      # `AgentCat.track` and retried on every dispatch, so a process that loads the
      # HTTP transport *after* `track` still starts capturing headers (from the next
      # request on). A no-op for a process without the class or without `rack`.
      sig { void }
      def install!
        return if @installed

        transport = transport_class
        return if transport.nil?
        return unless PrivateMembers.verify(PrivateMembers::STREAMABLE_HTTP_TRANSPORT_CALL)

        INSTALL_MUTEX.synchronize do
          transport.prepend(TransportHook) unless transport.ancestors.include?(TransportHook)
          @installed = true
        end
      end

      # The `parameters.extra` hash for one Rack env, or nil when there's nothing to
      # report. Never raises: a malformed env (an older Rack, a non-Hash) is a miss,
      # not a broken tool call.
      sig { params(env: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
      def extra_from_env(env)
        return nil unless env.is_a?(Hash)

        headers = headers_from_env(env)
        url = url_from_env(env)
        return nil if headers.empty? && url.nil?

        info = T.let({"headers" => headers}, T::Hash[String, T.untyped])
        info["url"] = url if url
        {"requestInfo" => info}
      end

      # Makes `extra` (and the Rack `env` it came from) ambient and returns whatever was
      # ambient before, so a nested or re-entrant dispatch restores correctly. Pass the
      # return value to `restore`.
      sig { params(extra: T.nilable(T::Hash[String, T.untyped]), env: T.untyped).returns(T.untyped) }
      def capture(extra, env = nil)
        previous = [Thread.current[KEY], Thread.current[ENV_KEY]]
        Thread.current[KEY] = extra
        Thread.current[ENV_KEY] = env
        previous
      end

      sig { params(previous: T.untyped).void }
      def restore(previous)
        extra, env = previous.is_a?(Array) ? previous : [previous, nil]
        Thread.current[KEY] = extra
        Thread.current[ENV_KEY] = env
      end

      # The ambient `extra` for the request being handled on this fiber right now, or
      # nil outside a captured HTTP request (stdio, a background call, tests).
      sig { returns(T.nilable(T::Hash[String, T.untyped])) }
      def current
        value = Thread.current[KEY]
        value.is_a?(Hash) ? value : nil
      end

      # The Rack env of the request being handled on this fiber right now, or nil
      # outside a captured HTTP request.
      sig { returns(T.untyped) }
      def current_env
        Thread.current[ENV_KEY]
      end

      # Wraps a deferred Rack body (`body.call(stream)`) so the request's `extra` is
      # ambient for exactly the duration of that dispatch. Deliberately a plain `proc`,
      # not a lambda or a delegator: the web server decides whether a response body is a
      # streaming/callable one by `respond_to?(:call)`, so the wrapper has to look like
      # the original body and nothing else.
      sig { params(body: T.untyped, extra: T::Hash[String, T.untyped], env: T.untyped).returns(Proc) }
      def scoped_body(body, extra, env = nil)
        proc do |stream|
          previous = capture(extra, env)
          begin
            body.call(stream)
          ensure
            restore(previous)
          end
        end
      end

      private

      # The `mcp` gem autoloads the transport, and loading it raises LoadError when the
      # bundle has no `rack` (the gem doesn't depend on it). A stdio server has no rack
      # and no headers to capture, so that is a miss, not a reason for `track` to raise.
      # The miss is remembered: a failed autoload would try to require rack again on
      # every dispatch.
      sig { returns(T.untyped) }
      def transport_class
        return nil if @transport_unloadable
        return nil unless defined?(::MCP::Server::Transports::StreamableHTTPTransport)

        ::MCP::Server::Transports::StreamableHTTPTransport
      rescue LoadError
        @transport_unloadable = true
        nil
      end

      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T::Hash[String, String]) }
      def headers_from_env(env)
        headers = T.let({}, T::Hash[String, String])
        env.each do |raw_key, raw_value|
          name = header_name(raw_key.to_s)
          next if name.nil?

          value = normalize_value(raw_value)
          next if value.nil?

          headers[name] = headers.key?(name) ? "#{headers[name]}, #{value}" : value
        end
        headers
      end

      # The full URL as the client asked for it, like PHP's `HttpContext::url`: the
      # scheme, the `Host` header (else Rack's `SERVER_NAME`/`SERVER_PORT`) and the raw
      # request URI, query as sent. nil without a host: no URL is made up.
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(T.nilable(String)) }
      def url_from_env(env)
        scheme = url_scheme(env)
        host = url_host(env, scheme)
        return nil if host.nil?

        "#{scheme}://#{host}#{request_uri(env)}"
      rescue
        nil
      end

      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(String) }
      def url_scheme(env)
        scheme = env["rack.url_scheme"]
        return scheme if scheme.is_a?(String) && !scheme.empty?

        https = env["HTTPS"]
        (https.is_a?(String) && !https.empty? && https.downcase != "off") ? "https" : "http"
      end

      sig { params(env: T::Hash[T.untyped, T.untyped], scheme: String).returns(T.nilable(String)) }
      def url_host(env, scheme)
        host = env["HTTP_HOST"]
        return host if host.is_a?(String) && !host.empty?

        name = env["SERVER_NAME"]
        return nil unless name.is_a?(String) && !name.empty?

        port = env["SERVER_PORT"].to_s
        default_port = (scheme == "https") ? "443" : "80"
        (port.empty? || port == default_port) ? name : "#{name}:#{port}"
      end

      # `REQUEST_URI` is not in the Rack spec, but Puma, WEBrick and Unicorn set it to
      # the raw request target. Without it, Rack's own parts: script, path, query.
      sig { params(env: T::Hash[T.untyped, T.untyped]).returns(String) }
      def request_uri(env)
        raw = env["REQUEST_URI"]
        return raw if raw.is_a?(String) && raw.start_with?("/")

        path = "#{env["SCRIPT_NAME"]}#{env["PATH_INFO"]}"
        query = env["QUERY_STRING"].to_s
        query.empty? ? path : "#{path}?#{query}"
      end

      # `HTTP_`-prefixed keys are the Rack convention for request headers; the two
      # content keys are the non-prefixed exceptions Rack itself defines.
      sig { params(key: String).returns(T.nilable(String)) }
      def header_name(key)
        return key.delete_prefix("HTTP_").downcase.tr("_", "-") if key.start_with?("HTTP_")
        return "content-type" if key == "CONTENT_TYPE"
        return "content-length" if key == "CONTENT_LENGTH"

        nil
      end

      sig { params(value: T.untyped).returns(T.nilable(String)) }
      def normalize_value(value)
        case value
        when nil then nil
        when String then value
        when Array then value.join(", ")
        else value.to_s
        end
      end
    end

    # Prepended to `MCP::Server::Transports::StreamableHTTPTransport`. `call(env)` is the
    # transport's Rack entry point; every HTTP path (stateless modern, `initialize`, plain
    # JSON) dispatches inside it, so the ambient headers are in scope when the interceptor
    # builds the event. The sessionful streamable path is the exception: it hands back a
    # *callable* Rack body (`proc { |stream| ... }`) that the web server invokes only after
    # `call` has returned, so the eager capture is already gone by the time the tool runs.
    # For that shape we re-scope the ambient around the body's own invocation — the wrapper
    # is a plain `proc` too, so the server keeps treating the body exactly as before.
    module TransportHook
      extend T::Sig

      sig { params(env: T.untyped).returns(T.untyped) }
      def call(env)
        # Feature off at run time (`PrivateMembers`): the request goes through untouched.
        return super unless PrivateMembers.enabled?(PrivateMembers::STREAMABLE_HTTP_TRANSPORT_CALL.feature)

        extra = AgentCat::RequestContext.extra_from_env(env)
        previous = AgentCat::RequestContext.capture(extra, env)

        result = begin
          super
        ensure
          AgentCat::RequestContext.restore(previous)
        end

        # Only ever reshape a plain Rack triple whose body is callable; anything else is
        # handed back byte-for-byte, so the hook can't alter behavior on a gem version
        # whose transport returns something we don't recognize.
        return result if extra.nil? || !result.is_a?(Array) || result.size < 3 || !result[2].respond_to?(:call)

        result.dup.tap { |rack_response| rack_response[2] = AgentCat::RequestContext.scoped_body(result[2], extra, env) }
      end
    end
  end
end
