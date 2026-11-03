# typed: true

require_relative "interceptor"
require_relative "schema/prompts"

module AgentCat
  # Installs AgentCat instrumentation on one server through its adapter:
  # registers the `get_more_tools` helper, injects the AgentCat parameters into
  # every tool schema and intercepts every tool call.
  class Tracker
    extend T::Sig

    GET_MORE_TOOLS = "get_more_tools"

    sig { returns(T.untyped) }
    attr_reader :adapter

    sig { returns(T.nilable(String)) }
    attr_reader :project_id

    sig { returns(AgentCat::Options) }
    attr_reader :options

    sig { params(adapter: T.untyped, project_id: T.nilable(String), options: AgentCat::Options).void }
    def initialize(adapter:, project_id:, options:)
      @adapter = adapter
      @project_id = project_id
      @options = options
      @reported_collisions = T.let(Set.new, T::Set[[String, String]])
      # handle => its Interceptor, for the calls the gem rejects before the handle runs.
      @interceptors = T.let({}.compare_by_identity, T::Hash[AgentCat::ToolHandle, Interceptor])
      @interceptors_mutex = T.let(Mutex.new, Mutex)
    end

    sig { returns(T.self_type) }
    def install!
      warn_if_stateless_without_identify
      if options.enable_report_missing
        # A host-defined get_more_tools keeps its own params, so we need to know
        # ownership before registering, not just match by name afterward.
        @registered_get_more_tools = T.let(adapter.tool_handles.none? { |handle| handle.name == GET_MORE_TOOLS }, T.nilable(T::Boolean))
        register_get_more_tools
      end
      sync!
      adapter.before_dispatch { sync! }
      adapter.watch_rejected_calls
      self
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def server_info
      @server_info ||= adapter.server_info
    end

    # `[name, description, schema_opts]` triples added to every tool schema and stripped
    # before the tool runs. Same order and requiredness as the Go/TS SDKs: handles first
    # (`session_id`, `agent_id`), then `context`, all three listed as required.
    # `enable_tracing: false` drops the handles, `enable_tool_call_context: false` drops
    # `context`. Required
    # is soft (see `ToolHandle#add_input_parameter`): it nudges the agent to fill them in,
    # but a call without them still runs. `placeholder` is what the `mcp` gem's own
    # required check gets in place of a missing one - `start` for `session_id` so it
    # also passes the pattern.
    sig { returns(T::Array[[String, String, T::Hash[Symbol, T.untyped]]]) }
    def injected_parameters
      @injected_parameters ||= begin
        params = T.let([], T::Array[[String, String, T::Hash[Symbol, T.untyped]]])
        if options.enable_tracing
          unless options.host_managed_sessions? || options.stateless?
            params << ["session_id", Schema::SESSION_ID_DESCRIPTION, {required: true, pattern: Schema::SESSION_ID_PATTERN, placeholder: "start"}]
          end
          params << ["agent_id", Schema::AGENT_ID_DESCRIPTION, {required: true}] if options.enable_agent_tracking
        end
        params << ["context", options.context_description, {required: true}] if options.enable_tool_call_context
        params
      end
    end

    sig { returns(T::Array[String]) }
    def injected_parameter_names
      @injected_parameter_names ||= injected_parameters.map(&:first)
    end

    # The interceptor that records a call to `tool` the gem rejected before it ran: the
    # handle's own, or for no tool at all (an unknown name) a new one that owns every
    # injected parameter, like TS. nil for a tool AgentCat hasn't instrumented.
    sig { params(tool: T.untyped, name: T.untyped).returns(T.nilable(Interceptor)) }
    def interceptor_for(tool, name)
      return Interceptor.new(handle: nil, tracker: self, tool_name: name.is_a?(String) ? name : nil) if tool.nil?
      return nil unless tool.is_a?(AgentCat::ToolHandle)

      @interceptors_mutex.synchronize { @interceptors[tool] }
    end

    private

    # Instruments every tool the adapter currently knows about. `instrument` is a no-op on
    # a handle it has already wrapped, so calling this again after the host registers more
    # tools only picks up the new ones. Run once at `install!` time and again right before
    # any request that needs it (`adapter.before_dispatch`), so a tool the host defines
    # after `track()` is instrumented by the time an agent discovers or calls it — even on
    # a server instance built fresh per request, whose first request is a direct
    # `tools/call` with no `tools/list` before it.
    sig { void }
    def sync!
      adapter.tool_handles.each { |handle| instrument(handle) }
    end

    sig { params(handle: AgentCat::ToolHandle).void }
    def instrument(handle)
      return if handle.intercepted?

      owned = owned_parameters_for(handle)
      injected_parameters.each do |name, description, schema_opts|
        handle.add_input_parameter(name, description: description, **T.unsafe(schema_opts)) if owned.include?(name)
      end
      # Nothing ever fills `mcp_session` with tracing off, so don't advertise it.
      handle.add_output_parameter(:mcp_session, mcp_session_output_schema) if options.enable_tracing
      interceptor = Interceptor.new(handle: handle, tracker: self, owned_parameters: owned)
      @interceptors_mutex.synchronize { @interceptors[handle] = interceptor }
      handle.intercept { |arguments, server_context, original| interceptor.call(arguments, server_context, original) }
    end

    # What `Interceptor` actually puts in `structuredContent.mcp_session` at runtime,
    # declared up front so a client validating against the output schema doesn't see an
    # undeclared field. Hook mode drops `status` — a host-managed session never gets one.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def mcp_session_output_schema
      hook_mode = options.host_managed_sessions?
      properties = {}
      properties[:session_id] = {type: "string", description: Schema::MCP_SESSION_SESSION_ID_DESCRIPTION} unless hook_mode
      properties[:agent_id] = {type: "string", description: Schema::MCP_SESSION_AGENT_ID_DESCRIPTION}
      properties[:status] = {type: "string", enum: %w[issued active unrecognized], description: Schema::MCP_SESSION_STATUS_DESCRIPTION} unless hook_mode

      {
        type: "object",
        description: hook_mode ? Schema::MCP_SESSION_FIELD_DESCRIPTION_HOOK_MODE : Schema::MCP_SESSION_FIELD_DESCRIPTION,
        properties: properties
      }
    end

    # A tool that already declares a parameter under one of our names owns it outright:
    # AgentCat neither injects its own copy, reads the value, nor strips it from the call,
    # so the host's argument reaches the host's handler untouched. The `get_more_tools` we
    # registered ourselves is the exception — the `context` in its schema is ours.
    #
    # A `oneOf`/`allOf`/`anyOf` schema gets nothing injected at all, silently: there's no
    # single `properties` object to add to, and no per-parameter "collision" to report,
    # since the tool never declared these names - injection is just structurally
    # impossible here, matching the Python SDK.
    sig { params(handle: AgentCat::ToolHandle).returns(T::Array[String]) }
    def owned_parameters_for(handle)
      # Its `context` is the whole point of the tool, so it stays ours (read into the event,
      # stripped before the handler) even with `enable_tool_call_context: false`.
      return injected_parameter_names | ["context"] if @registered_get_more_tools && handle.name == GET_MORE_TOOLS
      return [] if handle.composed_input_schema?

      collided, owned = injected_parameter_names.partition { |name| handle.input_parameter?(name) }
      collided.each { |name| report_collision(handle.name, name) }
      owned
    end

    # Once per tool and parameter (and, through `Log`, once a minute across the servers of
    # a per-request `track`). A `session_id` collision costs correlation for every call
    # to that tool, the others cost one attribute, hence the different levels.
    sig { params(tool_name: String, parameter: String).void }
    def report_collision(tool_name, parameter)
      return unless @reported_collisions.add?([tool_name, parameter])

      preamble = "tool #{tool_name.inspect} already declares a #{parameter.inspect} parameter, so AgentCat left it to the tool"
      if parameter == "session_id"
        Log.error("#{preamble}; its calls publish without a session id. Set the resolve_session_id option to keep them correlated.")
      else
        Log.warn("#{preamble}; its calls publish without #{parameter}.")
      end
    end

    sig { void }
    def warn_if_stateless_without_identify
      return unless options.stateless? && options.identify.nil?

      Log.warn("stateless mode is enabled without an identify hook; every event will be its own anonymous session")
    end

    sig { void }
    def register_get_more_tools
      adapter.register_tool(
        name: GET_MORE_TOOLS,
        description: Schema::GET_MORE_TOOLS_DESCRIPTION,
        input_schema: {
          type: "object",
          properties: {context: {type: "string", description: Schema::GET_MORE_TOOLS_CONTEXT_DESCRIPTION}},
          required: ["context"]
        },
        # Read-only like the Go/Python SDKs: it only reports a gap, never changes server state.
        annotations: {read_only_hint: true},
        call_fn: ->(_arguments, _server_context) { {content: [{type: "text", text: Schema::GET_MORE_TOOLS_PROMPT}]} }
      )
    end
  end
end
