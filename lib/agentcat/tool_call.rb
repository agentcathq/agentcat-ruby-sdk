# typed: strict

module AgentCat
  # One tool call, as the hooks in `Options` (`identify`, `resolve_session_id`,
  # `event_tags`, `event_properties`) see it. Every hook gets this one argument.
  #
  # AgentCat builds it on the request thread before any hook runs, so it holds the
  # HTTP headers of the request even though the hook itself runs on its own thread.
  # It is frozen all the way down: `arguments`, `meta` and `headers` are deep copies,
  # and changing them raises `FrozenError`. A hook cannot change what your tool gets
  # or what the event records.
  #
  # * `tool_name` — name of the tool the client called.
  # * `arguments` — the raw call arguments (String keys), including the parameters
  #   AgentCat injects (`session_id`, `agent_id`, `context`).
  # * `meta` — the raw `_meta` of the call (String keys); empty when there is none.
  # * `headers` — HTTP request headers with lower-case names, one String each
  #   (repeated values joined with ", "); empty on stdio.
  # * `client_name`, `client_version` — the MCP client, when it is known: from the
  #   `initialize` handshake, or from the SEP-2575 `_meta` clientInfo on a stateless call.
  # * `protocol_version` — the MCP protocol version the call itself claims (the
  #   SEP-2575 envelope or `_meta`), when it is known. nil after a plain `initialize`
  #   handshake, where the version belongs to the session, not the call.
  # * `transport_session_id` — the `Mcp-Session-Id` of the transport session; never the
  #   AgentCat session ID. nil on stdio and on stateless HTTP.
  # * `request` — the Rack env of the HTTP request, for details this class does not
  #   expose; nil on stdio. Not copied or frozen: treat it as read-only.
  # * `server_context` — the `mcp` gem's server context of the call. Not copied or
  #   frozen: treat it as read-only.
  class ToolCall
    extend T::Sig

    sig { returns(String) }
    attr_reader :tool_name

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :arguments

    sig { returns(T::Hash[String, T.untyped]) }
    attr_reader :meta

    sig { returns(T::Hash[String, String]) }
    attr_reader :headers

    sig { returns(T.nilable(String)) }
    attr_reader :client_name

    sig { returns(T.nilable(String)) }
    attr_reader :client_version

    sig { returns(T.nilable(String)) }
    attr_reader :protocol_version

    sig { returns(T.nilable(String)) }
    attr_reader :transport_session_id

    sig { returns(T.untyped) }
    attr_reader :request

    sig { returns(T.untyped) }
    attr_reader :server_context

    sig do
      params(
        tool_name: String,
        arguments: T::Hash[T.untyped, T.untyped],
        meta: T::Hash[T.untyped, T.untyped],
        headers: T::Hash[T.untyped, T.untyped],
        client_name: T.nilable(String),
        client_version: T.nilable(String),
        protocol_version: T.nilable(String),
        transport_session_id: T.nilable(String),
        request: T.untyped,
        server_context: T.untyped
      ).void
    end
    def initialize(
      tool_name:,
      arguments:,
      meta: {},
      headers: {},
      client_name: nil,
      client_version: nil,
      protocol_version: nil,
      transport_session_id: nil,
      request: nil,
      server_context: nil
    )
      @tool_name = T.let(frozen_copy(tool_name), String)
      @arguments = T.let(frozen_copy(arguments.transform_keys(&:to_s)), T::Hash[String, T.untyped])
      @meta = T.let(frozen_copy(meta.transform_keys(&:to_s)), T::Hash[String, T.untyped])
      @headers = T.let(frozen_copy(headers.to_h { |name, value| [name.to_s.downcase, value.to_s] }), T::Hash[String, String])
      @client_name = T.let(frozen_copy(client_name), T.nilable(String))
      @client_version = T.let(frozen_copy(client_version), T.nilable(String))
      @protocol_version = T.let(frozen_copy(protocol_version), T.nilable(String))
      @transport_session_id = T.let(frozen_copy(transport_session_id), T.nilable(String))
      @request = request
      @server_context = server_context
      freeze
    end

    private

    # A frozen deep copy of the Hash/Array/String structure. Other leaves (numbers, true,
    # false, nil, symbols) are immutable already; any other object is kept as is.
    # `copies` keeps a cyclic structure from looping and shared sub-objects shared.
    sig { params(value: T.untyped, copies: T::Hash[Integer, T.untyped]).returns(T.untyped) }
    def frozen_copy(value, copies = {})
      case value
      when Hash
        copies.fetch(value.object_id) do
          copy = copies[value.object_id] = {}
          value.each { |key, item| copy[frozen_copy(key, copies)] = frozen_copy(item, copies) }
          copy.freeze
        end
      when Array
        copies.fetch(value.object_id) do
          copy = copies[value.object_id] = []
          value.each { |item| copy << frozen_copy(item, copies) }
          copy.freeze
        end
      when String
        value.frozen? ? value : value.dup.freeze
      else
        value
      end
    end
  end
end
