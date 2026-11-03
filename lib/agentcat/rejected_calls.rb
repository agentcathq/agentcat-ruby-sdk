# typed: true

require_relative "clock"
require_relative "log"
require_relative "private_members"

module AgentCat
  # Events for `tools/call` requests the `mcp` gem answers before the tool runs (as in
  # TS): a name no tool has ("Tool not found", a JSON-RPC error) and arguments
  # that fail its required or schema check (an isError result). The TS SDK sees these
  # because it wraps the whole `tools/call` handler; the gem has no public seam for that,
  # so `ServerHook` is prepended to the server's singleton class over its private
  # `call_tool` (`PrivateMembers::SERVER_CALL_TOOL`).
  #
  # A call AgentCat's interceptor ran for is left alone: that call has its event already.
  module RejectedCalls
    extend T::Sig

    # One `tools/call` being watched.
    Watch = Struct.new(:interceptor, :tool, :request, :options, :server, :started_at)

    module ServerHook
      private

      # Same signature as the gem's `call_tool(request, session:, related_request_id:, ...)`;
      # the keywords differ by gem version, so they pass through untouched.
      def call_tool(request, **options)
        AgentCat::RejectedCalls.around(self, request, options) { super(request, **options) }
      end
    end

    class << self
      extend T::Sig

      # Prepends `ServerHook` once per server. false when the gem has no `call_tool`.
      sig { params(server: T.untyped).returns(T::Boolean) }
      def install(server)
        return false unless PrivateMembers.verify(PrivateMembers::SERVER_CALL_TOOL)

        singleton = server.singleton_class
        singleton.prepend(ServerHook) unless singleton.ancestors.include?(ServerHook)
        true
      rescue => e
        Log.warn("AgentCat cannot watch the calls the mcp gem rejects: #{e.class}")
        false
      end

      # Runs the gem's `call_tool` and records the call when the gem turned it away. The
      # gem's result and exception always reach the client as the gem made them, apart
      # from the mint-back on an isError result.
      sig { params(server: T.untyped, request: T.untyped, options: T::Hash[Symbol, T.untyped], block: T.proc.returns(T.untyped)).returns(T.untyped) }
      def around(server, request, options, &block)
        watch = watch(server, request, options)
        return yield if watch.nil?

        previous = Thread.current[Interceptor::RAN_KEY]
        Thread.current[Interceptor::RAN_KEY] = false
        ran = T.let(nil, T.nilable(T::Boolean))
        begin
          result = yield
        rescue => e
          ran = !!Thread.current[Interceptor::RAN_KEY]
          record(watch, error: e) unless ran || cancelled?(e)
          raise
        ensure
          ran = !!Thread.current[Interceptor::RAN_KEY] if ran.nil?
          Thread.current[Interceptor::RAN_KEY] = previous
        end
        return result if ran || ErrorCapture.capture_result(result).nil?

        record(watch, result: result)
      end

      private

      # nil when this call isn't AgentCat's to record: tracing off, the feature off, the
      # server not tracked, or a tool AgentCat hasn't instrumented.
      sig { params(server: T.untyped, request: T.untyped, options: T::Hash[Symbol, T.untyped]).returns(T.nilable(Watch)) }
      def watch(server, request, options)
        return nil unless PrivateMembers.enabled?(PrivateMembers::SERVER_CALL_TOOL.feature)

        tracker = AgentCat.tracker_for(server)
        return nil if tracker.nil? || !tracker.options.enable_tracing
        return nil unless request.is_a?(Hash)

        name = request.key?(:name) ? request[:name] : request["name"]
        tool = tracker.adapter.tool_named(name)
        interceptor = tracker.interceptor_for(tool, name)
        return nil if interceptor.nil?

        Watch.new(interceptor, tool, request, options, server, Clock.monotonic_now)
      rescue => e
        AgentCat.logger.debug { "RejectedCalls.watch failed: #{e.class}: #{e.message}" }
        nil
      end

      # Never raises: a failure here costs the event, never the gem's answer.
      sig { params(watch: Watch, result: T.untyped, error: T.nilable(StandardError)).returns(T.untyped) }
      def record(watch, result: nil, error: nil)
        request = watch.request
        arguments = request.key?(:arguments) ? request[:arguments] : request["arguments"]
        watch.interceptor.record_rejected(arguments || {}, server_context(watch), started_at: watch.started_at, result: result, error: error)
      rescue => e
        Log.error("could not record the rejected call of a tool: #{e.class}; the event is lost")
        AgentCat.logger.debug { "RejectedCalls.record failed: #{e.class}: #{e.message}" }
        result
      end

      # A real `MCP::ServerContext`, built like the gem builds the tool's own (its
      # `server_context_with_meta`), so the event reads the client, protocol version,
      # request id and `_meta` the same way. Only the keywords this gem version takes.
      sig { params(watch: Watch).returns(T.untyped) }
      def server_context(watch)
        context_class = Object.const_get("MCP::ServerContext")
        accepted = context_class.instance_method(:initialize).parameters.map { |_type, name| name }
        options = watch.options
        keywords = {
          progress: nil,
          notification_target: options[:session],
          related_request_id: options[:related_request_id],
          cancellation: options[:cancellation],
          envelope: options[:envelope]
        }.slice(*accepted)
        context_class.new(context_with_meta(watch.server.server_context, watch.request), **keywords)
      end

      sig { params(base: T.untyped, request: T::Hash[T.untyped, T.untyped]).returns(T.untyped) }
      def context_with_meta(base, request)
        meta = request[:_meta]
        if meta && base.is_a?(Hash)
          base.merge(_meta: meta)
        elsif meta && base.nil?
          {_meta: meta}
        else
          base
        end
      end

      # The gem's cancellation signal answers nothing (MCP cancellation spec), so it is
      # not a rejection.
      sig { params(error: StandardError).returns(T::Boolean) }
      def cancelled?(error)
        error.class.ancestors.any? { |ancestor| ancestor.name == "MCP::CancelledError" }
      end
    end
  end
end
