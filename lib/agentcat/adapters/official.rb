# typed: true

require "json"
require_relative "base"
require_relative "../tool_handle"
require_relative "../rejected_calls"

module AgentCat
  module Adapters
    # Adapter for the official `mcp` gem (`MCP::Server`).
    class Official < Base
      extend T::Sig

      sig { params(server: T.untyped).returns(T::Boolean) }
      def self.supports?(server)
        !!(defined?(::MCP::Server) && server.is_a?(::MCP::Server))
      end

      sig { returns(T::Hash[Symbol, T.untyped]) }
      def server_info
        {name: @server.name, version: @server.version}
      end

      sig { returns(T::Array[AgentCat::ToolHandle]) }
      def tool_handles
        tools = tools_hash
        return [] if tools.nil?

        tools.keys.filter_map { |name| wrap(name) }
      end

      sig do
        params(
          name: String,
          call_fn: T.untyped,
          description: T.nilable(String),
          input_schema: T.untyped,
          output_schema: T.untyped,
          annotations: T.untyped
        ).returns(T.nilable(AgentCat::ToolHandle))
      end
      def register_tool(name:, call_fn:, description: nil, input_schema: nil, output_schema: nil, annotations: nil)
        tools = tools_hash
        return nil if tools.nil?
        return wrap(name) if tools.key?(name)

        @server.define_tool(name: name, description: description, input_schema: input_schema, output_schema: output_schema, annotations: annotations) do |server_context: nil, **arguments|
          call_fn.call(arguments.transform_keys(&:to_s), server_context)
        end
        wrap(name)
      end

      # MCP::Server has no public "before dispatch" hook, so this wraps handle (most
      # transports) and handle_json (streamable HTTP's legacy path) to run sync first —
      # only when needs_sync? says it's actually needed, so the common case (a tool
      # we've already wrapped) skips the extra work. Safe to call once: track() already
      # guards against tracking the same server twice.
      sig { params(sync: T.proc.void).void }
      def before_dispatch(&sync)
        wrap_dispatch_method(AgentCat::PrivateMembers::SERVER_HANDLE, &sync)
        wrap_dispatch_method(AgentCat::PrivateMembers::SERVER_HANDLE_JSON, &sync)
      end

      sig { void }
      def watch_rejected_calls
        AgentCat::RejectedCalls.install(@server)
      end

      sig { params(name: T.untyped).returns(T.untyped) }
      def tool_named(name)
        tools_hash&.[](name)
      end

      # A `tools/list` always needs a fresh sync, so a tool registered since the last one is
      # listed with AgentCat's parameters. A `tools/call` only needs one when it names a tool
      # this adapter hasn't wrapped yet — the case a server's `install!` ran on but that
      # received no `tools/list` before its first real call: built fresh per request, or a
      # client that already knew the tool's name from an earlier instance's listing.
      #
      # `handle` receives an already-parsed request Hash; `handle_json` a raw JSON string. A
      # request this can't make sense of (malformed JSON, an unexpected shape) just skips the
      # sync — the original method's own error handling still sees it unchanged.
      sig { params(request: T.untyped).returns(T::Boolean) }
      def needs_sync?(request)
        parsed = request.is_a?(String) ? JSON.parse(request) : request
        return false unless parsed.is_a?(Hash)

        method = parsed[:method] || parsed["method"]
        case method
        when "tools/list"
          true
        when "tools/call"
          params = parsed[:params] || parsed["params"]
          name = params.is_a?(Hash) ? (params[:name] || params["name"]) : nil
          tools = tools_hash
          !name.nil? && !tools.nil? && !tools[name].is_a?(AgentCat::ToolHandle)
        else
          false
        end
      rescue JSON::ParserError, TypeError
        false
      end

      private

      # The server's own tools Hash, which AgentCat writes `ToolHandle`s into
      # (`PrivateMembers::SERVER_TOOLS`), or nil when that feature is off.
      sig { returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
      def tools_hash
        member = AgentCat::PrivateMembers::SERVER_TOOLS
        return nil unless AgentCat::PrivateMembers.enabled?(member.feature)

        tools = @server.tools
        return tools if tools.is_a?(Hash)

        AgentCat::PrivateMembers.missing!(member)
        nil
      rescue NoMethodError
        AgentCat::PrivateMembers.missing!(AgentCat::PrivateMembers::SERVER_TOOLS)
        nil
      end

      sig { params(member: AgentCat::PrivateMembers::Member, sync: T.proc.void).void }
      def wrap_dispatch_method(member, &sync)
        method_name = member.name.to_sym
        return unless AgentCat::PrivateMembers.enabled?(member.feature) && @server.respond_to?(method_name)

        original = @server.method(method_name)
        adapter = self
        @server.define_singleton_method(method_name) do |request, **kwargs|
          adapter.before_request(request, sync)
          original.call(request, **kwargs)
        end
      end

      public

      # Runs ahead of every request the wrapped `handle`/`handle_json` gets. Never raises:
      # the request always reaches the gem.
      sig { params(request: T.untyped, sync: T.proc.void).void }
      def before_request(request, sync)
        # Cheap retry (a boolean after the first success): if the HTTP transport wasn't
        # loaded when `track` ran, this installs the request-header hook the first time a
        # request reaches the server, so a later `require` doesn't silently cost headers.
        AgentCat::RequestContext.install!
        sync.call if needs_sync?(request)
      rescue => e
        AgentCat::Log.warn("AgentCat could not instrument new tools before a request: #{e.class}")
        AgentCat.logger.debug { "before_request failed: #{e.class}: #{e.message}" }
      end

      private

      sig { params(name: String).returns(T.nilable(AgentCat::ToolHandle)) }
      def wrap(name)
        tools = tools_hash
        return nil if tools.nil?

        tool = tools[name]
        return tool if tool.is_a?(AgentCat::ToolHandle)

        handle = AgentCat::ToolHandle.new(
          name: tool.name_value,
          title: tool.title_value,
          description: tool.description_value,
          icons: tool.icons_value,
          annotations: tool.annotations_value,
          meta: tool.meta_value,
          input_schema: tool.input_schema_value,
          output_schema: tool.output_schema_value,
          call_fn: call_fn_for(tool)
        )
        tools[name] = handle
        handle
      end

      # Mirrors `MCP::Server#accepts_server_context?`: a tool receives `server_context:` when its
      # `call` declares that keyword or accepts arbitrary keywords.
      sig { params(tool: T.untyped).returns(T.untyped) }
      def call_fn_for(tool)
        parameters = tool.method(:call).parameters
        accepts_context = parameters.any? do |type, param_name|
          type == :keyrest || (param_name == :server_context && (type == :key || type == :keyreq))
        end

        if accepts_context
          ->(arguments, server_context) { tool.call(**arguments.transform_keys(&:to_sym), server_context: server_context) }
        else
          ->(arguments, _server_context) { tool.call(**arguments.transform_keys(&:to_sym)) }
        end
      end
    end
  end
end
