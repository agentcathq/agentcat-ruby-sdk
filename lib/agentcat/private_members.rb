# typed: strict

require_relative "log"

module AgentCat
  # The manifest of `mcp` gem internals AgentCat depends on:
  # instance variables it reads, private methods it overrides, and public methods or
  # hashes it patches in a way the gem never promised to support. Each use site names
  # its member through a constant here, never a literal, so this file is the whole list.
  #
  # `check!` (run once per process by `AgentCat.track`) verifies every member against the
  # `mcp` gem that is loaded. A missing member logs one ERROR line naming it and the gem
  # version, and turns off the one feature that depends on it. Nothing here ever raises
  # into the host. A use site that finds its member gone at run time calls `missing!`
  # too, with the same effect.
  #
  # `test/test_private_members.rb` checks the manifest against the installed gem and
  # fails with the member's name; CONTRIBUTING.md says how to update it.
  module PrivateMembers
    extend T::Sig

    class Member < T::Struct
      extend T::Sig

      # The class that holds the member, as a constant string, so this file loads (and
      # the SDK runs) without the `mcp` gem.
      const :owner, String
      const :name, String
      # :ivar - an instance variable AgentCat reads
      # :private_method - a private method AgentCat overrides with a prepended module
      # :method - a method AgentCat overrides (subclass, prepend) or wraps per instance
      # :internal_hash - a Hash the gem keeps internally that AgentCat writes into
      const :kind, Symbol
      const :feature, Symbol

      sig { returns(String) }
      def label
        (kind == :ivar) ? "#{owner}#{name}" : "#{owner}##{name}"
      end
    end

    # What each feature does, for the log line that turns it off.
    FEATURES = T.let({
      tool_instrumentation: "tool call tracking",
      late_tool_sync: "tracking of tools defined after track",
      soft_required: "optional AgentCat parameters (they are not listed as required)",
      request_headers: "HTTP headers and URL in events",
      request_id: "requestId in events",
      legacy_client_info: "the client name and version in events",
      rejected_calls: "events for calls the mcp gem rejects (unknown tool, invalid arguments)"
    }.freeze, T::Hash[Symbol, String])

    # `MCP::Server#tools` is public, but AgentCat replaces its entries in place with
    # `AgentCat::ToolHandle`s (adapters/official.rb).
    SERVER_TOOLS = Member.new(owner: "MCP::Server", name: "tools", kind: :internal_hash, feature: :tool_instrumentation)
    # Wrapped per server, so a tool defined after `track` is instrumented before its first
    # listing or call (adapters/official.rb).
    SERVER_HANDLE = Member.new(owner: "MCP::Server", name: "handle", kind: :method, feature: :late_tool_sync)
    SERVER_HANDLE_JSON = Member.new(owner: "MCP::Server", name: "handle_json", kind: :method, feature: :late_tool_sync)
    # Overridden in a subclass, so the injected parameters are required in `tools/list`
    # but a call without them still reaches AgentCat (tool_handle.rb, `SoftRequired`).
    INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS = Member.new(owner: "MCP::Tool::InputSchema", name: "missing_required_arguments", kind: :method, feature: :soft_required)
    INPUT_SCHEMA_VALIDATE_ARGUMENTS = Member.new(owner: "MCP::Tool::InputSchema", name: "validate_arguments", kind: :method, feature: :soft_required)
    # Prepended, so the request's headers are in scope when the event is built
    # (request_context.rb, `TransportHook`).
    STREAMABLE_HTTP_TRANSPORT_CALL = Member.new(owner: "MCP::Server::Transports::StreamableHTTPTransport", name: "call", kind: :method, feature: :request_headers)
    # Private; prepended per server, so a call the gem rejects before the tool runs (no
    # such tool, invalid arguments) still gets an event (rejected_calls.rb).
    SERVER_CALL_TOOL = Member.new(owner: "MCP::Server", name: "call_tool", kind: :private_method, feature: :rejected_calls)
    # The JSON-RPC id of the `tools/call`; no reader (interceptor.rb, `request_id`).
    SERVER_CONTEXT_RELATED_REQUEST_ID = Member.new(owner: "MCP::ServerContext", name: "@related_request_id", kind: :ivar, feature: :request_id)
    # The session, for its clientInfo on gems without `ServerContext#client_info`
    # (interceptor.rb, `legacy_session_client`).
    SERVER_CONTEXT_NOTIFICATION_TARGET = Member.new(owner: "MCP::ServerContext", name: "@notification_target", kind: :ivar, feature: :legacy_client_info)

    ALL = T.let([
      SERVER_TOOLS,
      SERVER_HANDLE,
      SERVER_HANDLE_JSON,
      SERVER_CALL_TOOL,
      INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS,
      INPUT_SCHEMA_VALIDATE_ARGUMENTS,
      STREAMABLE_HTTP_TRANSPORT_CALL,
      SERVER_CONTEXT_RELATED_REQUEST_ID,
      SERVER_CONTEXT_NOTIFICATION_TARGET
    ].freeze, T::Array[Member])

    @mutex = T.let(Mutex.new, Mutex)
    @checked = T.let(false, T::Boolean)
    # member => true (present) or false (missing); a member whose class is not loaded yet
    # has no entry and is probed again on the next `verify`.
    @results = T.let({}, T::Hash[Member, T::Boolean])
    @disabled = T.let({}, T::Hash[Symbol, T::Boolean])
    @reported = T.let({}, T::Hash[Member, T::Boolean])

    class << self
      extend T::Sig

      # Verifies every member once per process. A no-op without the `mcp` gem.
      sig { void }
      def check!
        return if @checked
        return unless Object.const_defined?(:MCP)

        @checked = true
        ALL.each { |member| verify(member) }
      rescue
        nil
      end

      # true when `member` is on the loaded gem. Probes it the first time (and again
      # later while its class can't be loaded); a missing member is reported and its
      # feature turned off.
      sig { params(member: Member).returns(T::Boolean) }
      def verify(member)
        known = @mutex.synchronize { @results[member] }
        return known && enabled?(member.feature) unless known.nil?

        found = probe(member)
        return false if found.nil?

        @mutex.synchronize { @results[member] = found }
        missing!(member) unless found
        found && enabled?(member.feature)
      end

      sig { params(feature: Symbol).returns(T::Boolean) }
      def enabled?(feature)
        !@disabled.key?(feature)
      end

      # Turns the member's feature off and logs one line, once per member. Called by
      # `check!` and by a use site that finds its member gone at run time.
      sig { params(member: Member).void }
      def missing!(member)
        first = @mutex.synchronize do
          @results[member] = false
          @disabled[member.feature] = true
          !@reported.key?(member) && (@reported[member] = true)
        end
        return unless first

        Log.error("AgentCat cannot find #{member.label} in mcp #{mcp_version}, so #{FEATURES.fetch(member.feature)} is off")
      rescue
        nil
      end

      # true when `object` is an instance of the member's class: a use site only reports
      # a member missing from the gem's own objects, not from a host's stand-in.
      sig { params(object: T.untyped, member: Member).returns(T::Boolean) }
      def owner_instance?(object, member)
        object.class.ancestors.any? { |ancestor| ancestor.name == member.owner }
      rescue
        false
      end

      sig { returns(String) }
      def mcp_version
        T.unsafe(Object.const_get("MCP::VERSION")).to_s
      rescue NameError
        "unknown"
      end

      # true (present), false (missing) or nil (its class can't be loaded, as with the
      # HTTP transport in a process without Rack).
      sig { params(member: Member).returns(T.nilable(T::Boolean)) }
      def probe(member)
        owner = resolve(member.owner)
        return nil if owner.nil?

        case member
        when SERVER_TOOLS then server_tools_hash?(owner)
        when SERVER_HANDLE, SERVER_HANDLE_JSON then public_method?(owner, member.name)
        when INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS then soft_missing_required?(owner)
        when INPUT_SCHEMA_VALIDATE_ARGUMENTS then soft_validate?(owner)
        when STREAMABLE_HTTP_TRANSPORT_CALL, SERVER_CALL_TOOL then own_method?(owner, member.name)
        else ivar_on_server_context?(owner, member.name)
        end
      rescue
        false
      end

      # Forgets every result and turns every feature back on, for `AgentCat.reset!`.
      sig { void }
      def reset!
        @mutex.synchronize do
          @checked = false
          @results.clear
          @disabled.clear
          @reported.clear
        end
      end

      private

      sig { params(name: String).returns(T.untyped) }
      def resolve(name)
        # `mcp` autoloads MCP::Server, and only mcp/server.rb requires mcp/server_context:
        # MCP::ServerContext has no autoload of its own. Load the server first, so that a
        # probe does not depend on what the process happened to load before it.
        Object.const_get("MCP::Server") if name.start_with?("MCP::")
        Object.const_get(name)
      rescue NameError, LoadError
        nil
      end

      sig { params(server_class: T.untyped).returns(T::Boolean) }
      def server_tools_hash?(server_class)
        server_class.new(name: "agentcat_probe").tools.is_a?(Hash)
      end

      # A method the class itself defines (a prepended module of ours doesn't count),
      # taking the request (or Rack env) as its first argument.
      sig { params(klass: T.untyped, name: String).returns(T::Boolean) }
      def own_method?(klass, name)
        return false unless klass.method_defined?(name.to_sym) || klass.private_method_defined?(name.to_sym)

        method = klass.instance_method(name.to_sym)
        method = method.super_method while method && method.owner != klass
        first_argument?(method)
      end

      sig { params(klass: T.untyped, name: String).returns(T::Boolean) }
      def public_method?(klass, name)
        return false unless klass.public_method_defined?(name.to_sym)

        first_argument?(klass.instance_method(name.to_sym))
      end

      sig { params(method: T.untyped).returns(T::Boolean) }
      def first_argument?(method)
        return false if method.nil?

        type, = method.parameters.first
        type == :req
      end

      # The gem's `missing_required_arguments?` has to go through the overridden
      # `missing_required_arguments`, or a soft name would still be enforced.
      sig { params(schema_class: T.untyped).returns(T::Boolean) }
      def soft_missing_required?(schema_class)
        return false unless schema_class.method_defined?(:missing_required_arguments)

        !probe_schema(schema_class).missing_required_arguments?({})
      end

      sig { params(schema_class: T.untyped).returns(T::Boolean) }
      def soft_validate?(schema_class)
        return false unless schema_class.method_defined?(:validate_arguments)

        probe_schema(schema_class).validate_arguments({})
        true
      end

      sig { params(schema_class: T.untyped).returns(T.untyped) }
      def probe_schema(schema_class)
        hash = {type: "object", properties: {agentcat_probe: {type: "string"}}, required: ["agentcat_probe"]}
        SoftRequired.build(schema_class, hash, {"agentcat_probe" => ""})
      end

      # Checked on a real instance: the gem may still accept the keyword but stop
      # keeping it under this name.
      sig { params(context_class: T.untyped, ivar: String).returns(T::Boolean) }
      def ivar_on_server_context?(context_class, ivar)
        accepted = context_class.instance_method(:initialize).parameters.map { |_type, name| name }
        keywords = {progress: nil, notification_target: nil, related_request_id: 1}.slice(*accepted)
        context_class.new(nil, **keywords).instance_variable_defined?(ivar.to_sym)
      end
    end
  end
end
