# typed: strict

module AgentCat
  module Adapters
    # Interface every server adapter implements. An adapter knows how to read the tools
    # of a particular MCP server implementation, replace them with `ToolHandle`s and
    # register additional tools.
    class Base
      extend T::Sig

      sig { params(server: T.untyped).returns(T::Boolean) }
      def self.supports?(server)
        raise NotImplementedError
      end

      sig { params(server: T.untyped).void }
      def initialize(server)
        @server = server
      end

      # @return [Hash] `{name:, version:}` of the wrapped server.
      sig { returns(T::Hash[Symbol, T.untyped]) }
      def server_info
        raise NotImplementedError
      end

      # Replaces every native tool on the server with a `ToolHandle` and returns the handles.
      # Tools that are already handles are returned as they are.
      sig { returns(T::Array[AgentCat::ToolHandle]) }
      def tool_handles
        raise NotImplementedError
      end

      # Registers a new tool and returns its `ToolHandle`. Returns the existing handle when a
      # tool with that name is already present, nil when the adapter can't hold handles.
      #
      # `call_fn` receives `(arguments, server_context)` where `arguments` is a string-keyed Hash.
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
        raise NotImplementedError
      end

      # Runs `sync` right before dispatching a `tools/list` (so tools registered after
      # `track()` show up instrumented) or a `tools/call` naming a tool we haven't wrapped
      # yet (covers a server built fresh per request, with no prior `tools/list`).
      # No-op by default — an adapter that can't see the request path just skips re-sync.
      sig { params(sync: T.proc.void).void }
      def before_dispatch(&sync)
      end

      # Records the calls the server rejects before any tool runs (unknown tool, invalid
      # arguments). No-op by default.
      sig { void }
      def watch_rejected_calls
      end

      # The tool the server holds under `name` (a `ToolHandle` once instrumented), or nil.
      sig { params(name: T.untyped).returns(T.untyped) }
      def tool_named(name)
        nil
      end
    end
  end
end
