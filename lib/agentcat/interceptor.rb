# typed: true

require "time"
require_relative "diagnostics"
require_relative "schema/prompts"
require_relative "session_manager"
require_relative "user_identity"
require_relative "unredacted_event"
require_relative "error_capture"
require_relative "event_pipeline"
require_relative "hooks"
require_relative "tags"
require_relative "tool_call"
require_relative "version"
require_relative "private_members"

module AgentCat
  # The per-tool call pipeline that Tracker installs on every ToolHandle:
  #
  # 1. normalize argument keys to strings
  # 2. resolve the session (host resolver, agent-supplied id, or mint one)
  # 3. strip our injected params and invoke the real tool
  # 4. mint the session id back into the result if we issued one
  # 5. build an event, run the hook pipeline, publish it best-effort
  class Interceptor
    extend T::Sig

    EVENT_TYPE = "mcp:tools/call"

    # Reserved MCP `_meta` keys (SEP-2575) carrying the caller's identity and protocol
    # version. On a "modern" stateless request the `mcp` gem lifts these into the
    # per-request envelope; on a partial/legacy request they stay in `_meta`, which is
    # where the Go/TS SDKs read them too. Both spellings are kept because the wire uses
    # these fully-qualified string keys, but callers may hand us symbol keys.
    META_CLIENT_INFO_KEY = "io.modelcontextprotocol/clientInfo"
    META_PROTOCOL_VERSION_KEY = "io.modelcontextprotocol/protocolVersion"

    # source: :minted, :supplied, :invalid, :hook, :stateless, or :foreign.
    Session = Struct.new(:id, :source)

    # The resource name of a call that names no tool, same as TS.
    UNKNOWN_TOOL = "Unknown Tool"

    # Fiber-local flag set whenever an interceptor runs, so `RejectedCalls` can tell a
    # call the `mcp` gem turned away before the tool from one the tool answered.
    RAN_KEY = :agentcat_interceptor_ran

    # owned_parameters: the injected params we actually own on this tool and have to
    # strip before it runs. If the tool declares a name itself, it's not in this list,
    # and the tool keeps both the value and whatever it means.
    #
    # `handle` is nil for a call the `mcp` gem rejected because no tool has that name;
    # `tool_name` is then the name the call asked for.
    sig { params(handle: T.nilable(AgentCat::ToolHandle), tracker: AgentCat::Tracker, owned_parameters: T.nilable(T::Array[String]), tool_name: T.nilable(String)).void }
    def initialize(handle:, tracker:, owned_parameters: nil, tool_name: nil)
      @handle = handle
      @tracker = tracker
      @owned_parameters = T.let(owned_parameters || tracker.injected_parameter_names, T::Array[String])
      name = handle ? handle.name : tool_name.to_s
      @tool_name = T.let(name.empty? ? UNKNOWN_TOOL : name, String)
    end

    sig { params(arguments: T.nilable(T::Hash[T.untyped, T.untyped]), server_context: T.untyped, original: T.untyped).returns(T.untyped).checked(:tests) }
    def call(arguments, server_context, original)
      Thread.current[RAN_KEY] = true
      args = (arguments || {}).transform_keys(&:to_s)
      # Tracing off: just keep our injected params (context, if that's still on) away from
      # the handler. No identify, no session, no mint-back, no event.
      return original.call(args.except(*T.unsafe(@owned_parameters)), server_context) unless @tracker.options.enable_tracing

      # Built here, on the request thread: the hooks run on threads of their own, where
      # the request's HTTP headers (fiber-local) are out of reach. Built before the tool
      # runs, so the hooks after it still see the arguments the agent sent.
      tool_call = build_tool_call(args, server_context)
      identity = resolve_identity(tool_call)
      session = resolve_session(args, tool_call)
      # T.unsafe: except(*array) hits a known Sorbet splat limitation (srb.help/7019)
      stripped = args.except(*T.unsafe(@owned_parameters))
      started_at = Clock.monotonic_now

      begin
        result = original.call(stripped, server_context)
      rescue => error
        publish(args, session, server_context, tool_call, identity: identity, error: error, started_at: started_at)
        raise
      end

      # The mint-back (session_id text, `mcp_session` mirror) is for the agent only. The
      # event records the tool's own result, same as the TS SDK, so the dashboard and the
      # output token count show what the tool returned, not our bookkeeping.
      publish(args, session, server_context, tool_call, identity: identity, result: result, started_at: started_at)
      # An `input_required` round (SEP-2322 MRTR) isn't the answer yet: the agent will
      # retry with its input, and that completing round carries the mint-back. Same as
      # the Go/TS SDKs.
      return result if input_required?(result)

      safe_mint_back(result, session, args)
    end

    # A call the `mcp` gem answered before the tool ran (as in TS): no tool by that
    # name (`error`, the gem's exception, which it re-raises), or arguments that failed
    # its required or schema check (`result`, its isError result). Records one error
    # event, resolving the session like a real call, and returns the result to send: an
    # isError result gets the mint-back like any other (TS v1), an exception gets none.
    sig do
      params(
        arguments: T.untyped,
        server_context: T.untyped,
        started_at: Float,
        result: T.untyped,
        error: T.nilable(StandardError)
      ).returns(T.untyped).checked(:tests)
    end
    def record_rejected(arguments, server_context, started_at:, result: nil, error: nil)
      args = arguments.is_a?(Hash) ? arguments.transform_keys(&:to_s) : {}
      tool_call = build_tool_call(args, server_context)
      identity = resolve_identity(tool_call)
      session = resolve_session(args, tool_call)
      error_data = error ? nil : ErrorCapture.capture_result(result)
      publish(args, session, server_context, tool_call, identity: identity, result: result, error: error, error_data: error_data, started_at: started_at)
      error ? result : safe_mint_back(result, session, args)
    end

    private

    # `mint_back` builds a new response object (or Hash) from the tool's real result - a
    # bug there must never turn a successful tool call into a failed one. Falls back to
    # the tool's own, unannotated result; the agent loses the session text/mcp_session
    # mirror for this one call, never the call itself.
    sig { params(result: T.untyped, session: Session, args: T::Hash[String, T.untyped]).returns(T.untyped) }
    def safe_mint_back(result, session, args)
      mint_back(result, session, args)
    rescue => e
      Log.warn("could not add the session to the result of tool #{@tool_name}: #{e.class}")
      AgentCat.logger.debug { "mint_back failed for #{@tool_name}: #{e.class}: #{e.message}" }
      result
    end

    sig { returns(Float) }
    def hook_timeout
      @tracker.options.hook_timeout
    end

    sig { params(name: String).returns(T::Boolean) }
    def owns?(name)
      @owned_parameters.include?(name)
    end

    sig { params(args: T::Hash[String, T.untyped], name: String).returns(T.untyped) }
    def owned_value(args, name)
      owns?(name) ? args[name] : nil
    end

    # The hooks' one argument, or nil when no hook is set. A failure to
    # build it costs the hooks for this call, never the call: each hook is then skipped.
    sig { params(args: T::Hash[String, T.untyped], server_context: T.untyped).returns(T.nilable(ToolCall)).checked(:tests) }
    def build_tool_call(args, server_context)
      options = @tracker.options
      return nil unless options.identify || options.resolve_session_id || options.event_tags || options.event_properties

      http = RequestContext.current || {}
      headers = http.dig("requestInfo", "headers")
      headers = {} unless headers.is_a?(Hash)
      session_id = headers["mcp-session-id"]
      client = client_info(server_context)
      ToolCall.new(
        tool_name: @tool_name,
        arguments: args,
        meta: request_meta(server_context) || {},
        headers: headers,
        client_name: string_or_nil(client && (client[:name] || client["name"])),
        client_version: string_or_nil(client && (client[:version] || client["version"])),
        protocol_version: protocol_version(server_context),
        transport_session_id: (session_id.is_a?(String) && !session_id.empty?) ? session_id : nil,
        request: RequestContext.current_env,
        server_context: server_context
      )
    rescue => e
      Log.warn("could not prepare the hook input for tool #{@tool_name}: #{e.class}; its hooks are skipped for this call")
      AgentCat.logger.debug { "ToolCall build failed for #{@tool_name}: #{e.class}: #{e.message}" }
      nil
    end

    sig { params(value: T.untyped).returns(T.nilable(String)) }
    def string_or_nil(value)
      value&.to_s
    end

    sig { params(tool_call: T.nilable(ToolCall)).returns(T.nilable(UserIdentity)).checked(:tests) }
    def resolve_identity(tool_call)
      identify = @tracker.options.identify
      return nil unless identify && tool_call

      identity = Hooks.run(identify, tool_call, timeout: hook_timeout, name: "identify")
      return identity if identity.nil? || identity.is_a?(UserIdentity)

      Log.warn("identify hook returned #{identity.class}, not an AgentCat::UserIdentity; the event has no identified user")
      nil
    rescue => e
      Log.warn("identify failed with #{e.class}; the event has no identified user")
      AgentCat.logger.debug { "identify hook failed: #{e.class}: #{e.message}" }
      nil
    end

    sig { params(args: T::Hash[String, T.untyped], tool_call: T.nilable(ToolCall)).returns(Session).checked(:tests) }
    def resolve_session(args, tool_call)
      return Session.new(nil, :stateless) if @tracker.options.stateless?

      if (resolver = @tracker.options.resolve_session_id)
        return resolve_host_session(resolver, tool_call)
      end

      # Tool owns its own session_id param — not ours to read.
      return Session.new(nil, :foreign) unless owns?("session_id")

      provided = args["session_id"]
      trimmed = provided.is_a?(String) ? provided.strip : nil

      if trimmed.nil? || trimmed.empty? || SessionManager.start_sentinel?(trimmed)
        Session.new(SessionManager.mint_session_id, :minted)
      elsif SessionManager.valid?(trimmed)
        Session.new(trimmed, :supplied)
      else
        # not ours — don't reissue, just go sessionless and let them resend or send "start"
        Session.new(nil, :invalid)
      end
    end

    # The host's correlation id never goes out verbatim; it's derived into a ses_ KSUID
    # (SHA-256, same as Go/TypeScript). If the hook comes back blank or raises, we still
    # mint a session rather than publishing with none — fail-open, same as Go/Java. Source
    # stays :hook either way, not :minted: hook mode never puts session_id in the tool
    # schema or shows mint-back text, and that has to hold whether the id came from the
    # resolver or from this fallback.
    sig { params(resolver: T.untyped, tool_call: T.nilable(ToolCall)).returns(Session).checked(:tests) }
    def resolve_host_session(resolver, tool_call)
      resolved = tool_call && host_session_id(resolver, tool_call)
      trimmed = resolved.is_a?(String) ? resolved.strip : nil

      if trimmed.nil? || trimmed.empty?
        Session.new(SessionManager.mint_session_id, :hook)
      else
        Session.new(SessionManager.derive_session_id(trimmed, @tracker.project_id), :hook)
      end
    end

    sig { params(resolver: T.untyped, tool_call: ToolCall).returns(T.nilable(String)).checked(:tests) }
    def host_session_id(resolver, tool_call)
      id = Hooks.run(resolver, tool_call, timeout: hook_timeout, name: "resolve_session_id")
      id&.to_s
    rescue => e
      Log.warn("resolve_session_id failed with #{e.class}; the call gets a new session")
      AgentCat.logger.debug { "resolve_session_id hook failed: #{e.class}: #{e.message}" }
      nil
    end

    # Prepends a text block and sets _meta.agentcat when there's something for the agent
    # to actually do (:minted, :invalid). Every other source still gets a mcp_session
    # mirror on structured_content when there's one to report - :supplied as "active",
    # :hook/:foreign/:stateless as agent_id alone, no status - just silently, with no text
    # block and no _meta, since the agent already knows its session_id and hook/foreign
    # modes never show it one at all. Matches the Go SDK's v2.1.0 wire shape.
    sig { params(result: T.untyped, session: Session, args: T::Hash[String, T.untyped]).returns(T.untyped).checked(:tests) }
    def mint_back(result, session, args)
      case session.source
      when :minted
        text = mint_back_text(Schema::MINT_BACK_HEADER_ISSUED, "session_id: #{session.id}", Schema::MINT_BACK_ISSUED_BODY)
        annotate(result, text, {session_id: session.id, instructions: text}, mcp_session_payload(session.id, "issued", args))
      when :invalid
        text = mint_back_text(Schema::MINT_BACK_HEADER_UNRECOGNIZED, Schema::MINT_BACK_UNRECOGNIZED_BODY)
        annotate(result, text, {instructions: text}, mcp_session_payload(nil, "unrecognized", args))
      when :supplied
        annotate(result, nil, nil, mcp_session_payload(session.id, "active", args))
      when :hook, :foreign, :stateless
        annotate(result, nil, nil, mcp_session_payload(nil, nil, args))
      else
        # Unreachable - `Session.source` is one of the six values above - kept as a
        # defensive fallback rather than letting an unexpected value fall through to nil.
        result
      end
    end

    # Matches the Go/TS mint-back block shape: a `[session_id ...]` marker line an agent
    # can pattern-match on, then the rest.
    sig { params(lines: String).returns(String) }
    def mint_back_text(*lines)
      lines.join("\n")
    end

    sig { params(session_id: T.nilable(String), status: T.nilable(String), args: T::Hash[String, T.untyped]).returns(T::Hash[Symbol, T.untyped]) }
    def mcp_session_payload(session_id, status, args)
      {session_id: session_id, agent_id: owned_value(args, "agent_id"), status: status}.compact
    end

    # `text`/`annotation` are nil for a silent mirror (nothing new to tell the agent, but
    # still something to report structurally); `mcp_session` empty means there's nothing
    # at all to add, agent_id included, so the result passes through untouched.
    sig { params(result: T.untyped, text: T.nilable(String), annotation: T.nilable(T::Hash[Symbol, T.untyped]), mcp_session: T::Hash[Symbol, T.untyped]).returns(T.untyped).checked(:tests) }
    def annotate(result, text, annotation, mcp_session)
      return result if text.nil? && mcp_session.empty?

      if mcp_response?(result)
        annotated_response(result, text, annotation, mcp_session)
      elsif result.is_a?(Hash)
        annotated_hash(result, text, annotation, mcp_session)
      else
        result
      end
    end

    sig { params(result: T.untyped).returns(T::Boolean) }
    def mcp_response?(result)
      !!(defined?(::MCP::Tool::Response) && result.is_a?(::MCP::Tool::Response))
    end

    sig { params(response: T.untyped, text: T.nilable(String), annotation: T.nilable(T::Hash[Symbol, T.untyped]), mcp_session: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
    def annotated_response(response, text, annotation, mcp_session)
      content = text ? ([{type: "text", text: text}] + Array(response.content)) : response.content
      meta = (response.respond_to?(:meta) ? response.meta : nil) || {}
      options = {error: response.error?}
      if response.respond_to?(:structured_content)
        options[:structured_content] = if @handle&.output_schema && !mcp_session.empty?
          (response.structured_content || {}).merge(mcp_session: mcp_session)
        else
          response.structured_content
        end
      end
      options[:meta] = meta.merge(agentcat: annotation) if annotation && response_supports_meta?
      ::MCP::Tool::Response.new(content, **options)
    end

    sig { returns(T::Boolean) }
    def response_supports_meta?
      ::MCP::Tool::Response.instance_method(:initialize).parameters.any? { |_type, name| name == :meta }
    end

    sig { params(hash: T::Hash[T.untyped, T.untyped], text: T.nilable(String), annotation: T.nilable(T::Hash[Symbol, T.untyped]), mcp_session: T::Hash[Symbol, T.untyped]).returns(T::Hash[T.untyped, T.untyped]) }
    def annotated_hash(hash, text, annotation, mcp_session)
      string_keys = hash.keys.any?(String)
      key = ->(sym) { string_keys ? sym.to_s : sym }
      result = hash.dup

      result[key.call(:content)] = [{key.call(:type) => "text", key.call(:text) => text}] + Array(hash[key.call(:content)]) if text
      result[key.call(:_meta)] = (hash[key.call(:_meta)] || {}).merge(key.call(:agentcat) => annotation) if annotation

      structured_key = key.call(:structuredContent)
      if hash[structured_key].is_a?(Hash) && !mcp_session.empty?
        result[structured_key] = hash[structured_key].merge(key.call(:mcp_session) => mcp_session)
      end
      result
    end

    sig do
      params(
        args: T::Hash[String, T.untyped],
        session: Session,
        server_context: T.untyped,
        tool_call: T.nilable(ToolCall),
        started_at: Float,
        identity: T.nilable(UserIdentity),
        result: T.untyped,
        error: T.nilable(StandardError),
        error_data: T.nilable(T::Hash[String, T.untyped])
      ).void.checked(:tests)
    end
    def publish(args, session, server_context, tool_call, started_at:, identity: nil, result: nil, error: nil, error_data: nil)
      event = build_event(args, session, server_context, started_at: started_at, identity: identity, result: result, error: error, error_data: error_data)
      return if event.nil?

      event = apply_tags_and_properties(event, tool_call)
      return if event.nil?

      epoch = AgentCat.event_epoch
      AgentCat.event_queue(queue_size: @tracker.options.queue_size).enqueue do
        # The response shares its hashes, arrays and content blocks with the result the
        # agent is getting, possibly still being serialized on the request thread. Every
        # pipeline step (the customer's redact_event, sanitization, truncation) may edit the
        # event in place, so it gets its own copy first. Reading while the transport also
        # reads is fine; writing is not - a long text block would get cut to 32KB in
        # the agent's own response.
        event.response = own_copy(event.response)
        EventPipeline.run(event, @tracker, epoch: epoch, label: "the event of tool #{@tool_name}")
      end
    rescue => e
      Log.error("could not build the event for tool #{@tool_name}: #{e.class}; the event is lost")
      AgentCat.logger.debug { "failed to build event for #{@tool_name}: #{e.class}: #{e.message}" }
      nil
    end

    sig do
      params(
        args: T::Hash[String, T.untyped],
        session: Session,
        server_context: T.untyped,
        started_at: Float,
        identity: T.nilable(UserIdentity),
        result: T.untyped,
        error: T.nilable(StandardError),
        error_data: T.nilable(T::Hash[String, T.untyped])
      ).returns(UnredactedEvent).checked(:tests)
    end
    def build_event(args, session, server_context, started_at:, identity: nil, result: nil, error: nil, error_data: nil)
      client = client_info(server_context)
      response = serialize_result(result)
      UnredactedEvent.new(
        project_id: @tracker.project_id,
        id: EventId.mint,
        session_id: session.id,
        actor_id: identity&.user_id || owned_value(args, "agent_id"),
        event_type: EVENT_TYPE,
        resource_name: @tool_name,
        parameters: event_parameters(args, server_context),
        user_intent: owned_value(args, "context"),
        response: response,
        is_error: error ? true : error_result?(result),
        error: error ? ErrorCapture.capture(error) : error_data,
        duration: ((Clock.monotonic_now - started_at) * 1000).round,
        input_tokens: TokenEstimate.input_tokens(args),
        output_tokens: TokenEstimate.output_tokens(response),
        timestamp: Time.now.utc.iso8601(3),
        server_name: @tracker.server_info[:name],
        server_version: @tracker.server_info[:version],
        client_name: client && (client[:name] || client["name"]),
        client_version: client && (client[:version] || client["version"]),
        protocol_version: protocol_version(server_context),
        agentcat_version: AgentCat::VERSION,
        identify_actor_given_id: identity&.user_id,
        identify_actor_name: identity&.user_name,
        identify_data: identity&.user_data,
        context_supplied: !owned_value(args, "context").to_s.strip.empty?,
        via_get_more_tools: @tool_name == Tracker::GET_MORE_TOOLS,
        session_id_source: session.source.to_s,
        agent_id_source: actor_source(identity, args),
        agent_id: supplied_agent_id(args),
        mrtr: mrtr_round(result, server_context)
      )
    end

    # The event's `parameters`, same shape as the Go SDK: `{name, arguments, extra}`.
    # `arguments` is exactly what the agent sent (raw, unstripped). Keeping the arguments
    # under their own key means a tool argument that happens to be called `extra` can't
    # get clobbered by ours.
    #
    # `extra` follows the TS v1 request extra:
    # `{sessionId?, requestId, _meta?, requestInfo?: {headers, url?}, authInfo?}`, in
    # that order, no `method` key.
    #   - `sessionId`: the `Mcp-Session-Id` header (sessionful HTTP only)
    #   - `requestId`: the JSON-RPC id of this `tools/call`, on any transport
    #   - `_meta`: the request's own `_meta` as the client sent it (`progressToken`,
    #     `claudecode/toolUseId`...), on any transport
    #   - `requestInfo`: the incoming HTTP headers (one string each) and full URL, so
    #     AgentCat can tell which client called even when `_meta` has no identity
    #     (HTTP only)
    #   - `authInfo`: the `mcp` gem has no auth of its own, so this is whatever Hash
    #     the host put in its `server_context` as `auth_info` (or `authInfo`)
    # Left off entirely only when there's nothing to put in it (no request id either).
    sig { params(args: T::Hash[String, T.untyped], server_context: T.untyped).returns(T::Hash[String, T.untyped]) }
    def event_parameters(args, server_context)
      parameters = {"name" => @tool_name, "arguments" => args}
      extra = event_extra(server_context)
      parameters["extra"] = extra unless extra.empty?
      parameters
    end

    sig { params(server_context: T.untyped).returns(T::Hash[String, T.untyped]) }
    def event_extra(server_context)
      http = RequestContext.current || {}
      extra = T.let({}, T::Hash[String, T.untyped])
      session_id = http.dig("requestInfo", "headers", "mcp-session-id")
      extra["sessionId"] = session_id if session_id.is_a?(String) && !session_id.empty?
      request_id = request_id(server_context)
      extra["requestId"] = request_id unless request_id.nil?
      meta = request_meta(server_context)
      extra["_meta"] = meta unless meta.nil? || meta.empty?
      extra["requestInfo"] = http["requestInfo"] if http.key?("requestInfo")
      auth_info = auth_info(server_context)
      extra["authInfo"] = auth_info unless auth_info.nil?
      extra
    end

    # The JSON-RPC id of the `tools/call` (a String or an Integer, as the client sent
    # it). `MCP::ServerContext` keeps it as `@related_request_id` with no reader (mcp
    # 1.7.0), so it is read from there (`PrivateMembers`); a gem without it leaves
    # `requestId` off.
    sig { params(server_context: T.untyped).returns(T.untyped) }
    def request_id(server_context)
      id = private_ivar(server_context, PrivateMembers::SERVER_CONTEXT_RELATED_REQUEST_ID)
      (id.is_a?(String) || id.is_a?(Integer)) ? id : nil
    end

    # Reads one instance variable of the `PrivateMembers` manifest, or nil when its
    # feature is off. The gem's own object without it turns the feature off.
    sig { params(object: T.untyped, member: PrivateMembers::Member).returns(T.untyped) }
    def private_ivar(object, member)
      return nil unless PrivateMembers.enabled?(member.feature)

      ivar = member.name.to_sym
      return object.instance_variable_get(ivar) if object.instance_variable_defined?(ivar)

      PrivateMembers.missing!(member) if PrivateMembers.owner_instance?(object, member)
      nil
    rescue
      nil
    end

    # The request's auth, when the host has some: the `mcp` gem (1.7.0) has no auth
    # info, so this reads `auth_info`/`authInfo` from the host's `server_context`.
    sig { params(server_context: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def auth_info(server_context)
      return nil unless server_context.respond_to?(:[])

      %i[auth_info authInfo].each do |key|
        value = server_context[key]
        value = server_context[key.to_s] if value.nil?
        return value if value.is_a?(Hash) && !value.empty?
      end
      nil
    rescue
      nil
    end

    # The connecting client's own identity ("Claude Desktop", "Claude Code"...), resolved
    # per request exactly like the Go/TS SDKs:
    #
    #   1. `server_context.client_info` — the `mcp` gem's envelope-first resolution: the
    #      per-request `_meta` envelope on 2026 stateless requests, the `initialize`
    #      handshake's captured clientInfo on legacy ones.
    #   2. `_meta["io.modelcontextprotocol/clientInfo"]` — read straight from the request,
    #      because a stateless request that carries only clientInfo (no full envelope
    #      triple) is not classified as modern by the gem, so step 1 yields nil on a
    #      sessionless transport even though the identity is right there.
    #   3. Older `mcp` gems (0.23, 1.0) have no `ServerContext#client_info` at all, so
    #      the handshake's clientInfo is only on the session. See `legacy_session_client`.
    #
    # Not the same thing as identify, which is about the human using that client. nil if
    # the client skipped identifying itself (legal — it is self-reported).
    sig { params(server_context: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def client_info(server_context)
      info = server_context.respond_to?(:client_info) ? server_context.client_info : nil
      info = request_meta_value(server_context, META_CLIENT_INFO_KEY) unless info.is_a?(Hash)
      info = legacy_session_client(server_context) unless info.is_a?(Hash)
      info.is_a?(Hash) ? info : nil
    end

    # The clientInfo an old `mcp` gem stored on the session at `initialize`. Those gems
    # give no public way to reach the session from a ServerContext, so we read its
    # `@notification_target` (`PrivateMembers`). Only for gems without `client_info`: on
    # newer ones that method already covers the session, and a nil from it is a real
    # "not identified".
    sig { params(server_context: T.untyped).returns(T.untyped) }
    def legacy_session_client(server_context)
      return nil if server_context.respond_to?(:client_info)

      session = private_ivar(server_context, PrivateMembers::SERVER_CONTEXT_NOTIFICATION_TARGET)
      session.respond_to?(:client) ? session.client : nil
    rescue
      nil
    end

    # The MCP protocol version this request was made with. The envelope carries it on a
    # modern request; otherwise fall back to the reserved `_meta` key. `nil` when the
    # client negotiated it at the session level (legacy) or didn't declare it.
    sig { params(server_context: T.untyped).returns(T.nilable(String)) }
    def protocol_version(server_context)
      version = server_context.respond_to?(:protocol_version) ? server_context.protocol_version : nil
      unless version.is_a?(String) && !version.empty?
        version = request_meta_value(server_context, META_PROTOCOL_VERSION_KEY)
      end
      return version if version.is_a?(String) && !version.empty?

      nil
    end

    # Reads one reserved key out of the request's raw `_meta` hash.
    sig { params(server_context: T.untyped, key: String).returns(T.untyped) }
    def request_meta_value(server_context, key)
      request_meta(server_context)&.[](key)
    end

    # The request's raw `_meta` hash, keys as strings. `MCP::ServerContext` forwards `[]`
    # to the request context it wraps, which is where the gem merged `_meta` (see
    # `Server#server_context_with_meta`). Defensive on every axis: an older gem that
    # exposes no `[]`, a context that isn't a Hash, or a struct whose `[]` rejects the key.
    sig { params(server_context: T.untyped).returns(T.nilable(T::Hash[String, T.untyped])) }
    def request_meta(server_context)
      return nil unless server_context.respond_to?(:[])

      meta = server_context[:_meta]
      meta.is_a?(Hash) ? meta.transform_keys(&:to_s) : nil
    rescue
      nil
    end

    # identity wins regardless of agent tracking, hence checked first. After that,
    # owns?("agent_id") is false for one of two reasons — tracking's off, or this tool
    # collided on agent_id and we backed off — and enable_agent_tracking tells them apart.
    sig { params(identity: T.nilable(UserIdentity), args: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def actor_source(identity, args)
      return "identified" if identity
      return nil unless @tracker.options.enable_agent_tracking
      return "foreign" unless owns?("agent_id")

      owned_value(args, "agent_id").to_s.strip.empty? ? nil : "supplied"
    end

    # What the agent actually put in `agent_id`, or nil when tracking's off, the tool owns
    # that name, or the agent left it blank.
    sig { params(args: T::Hash[String, T.untyped]).returns(T.nilable(String)) }
    def supplied_agent_id(args)
      value = owned_value(args, "agent_id")
      (value.is_a?(String) && !value.strip.empty?) ? value : nil
    end

    sig { params(event: UnredactedEvent, tool_call: T.nilable(ToolCall)).returns(T.nilable(UnredactedEvent)).checked(:tests) }
    def apply_tags_and_properties(event, tool_call)
      return event if tool_call.nil?

      event.tags = event.tags.merge(run_tags_hook(tool_call))
      event.properties = event.properties.merge(run_properties_hook(tool_call))
      event
    end

    sig { params(tool_call: ToolCall).returns(T::Hash[String, String]).checked(:tests) }
    def run_tags_hook(tool_call)
      hook = @tracker.options.event_tags
      return {} unless hook

      value = Hooks.run(hook, tool_call, timeout: hook_timeout, name: "event_tags")
      Tags.sanitize(value, "event_tags")
    end

    sig { params(tool_call: ToolCall).returns(T::Hash[String, T.untyped]).checked(:tests) }
    def run_properties_hook(tool_call)
      hook = @tracker.options.event_properties
      return {} unless hook

      value = Hooks.run(hook, tool_call, timeout: hook_timeout, name: "event_properties")
      return value.transform_keys(&:to_s) if value.is_a?(Hash)

      Log.warn("event_properties hook returned #{value.class}, not a Hash; ignored") unless value.nil?
      {}
    end

    sig { params(result: T.untyped).returns(T.untyped) }
    def serialize_result(result)
      return nil if result.nil?
      return result.to_h if mcp_response?(result) || input_required_result?(result)

      result
    end

    # Which MRTR round this call is, for the `agentcat_mrtr` tag: "input_required" when
    # the tool asked the agent for more input, "continuation" when this call is the retry
    # carrying that input, nil for an ordinary call. A continuation that asks for input
    # again is tagged input_required, same as Go/TS.
    sig { params(result: T.untyped, server_context: T.untyped).returns(T.nilable(String)) }
    def mrtr_round(result, server_context)
      return "input_required" if input_required?(result)

      responses = server_context.respond_to?(:input_responses) ? server_context.input_responses : nil
      (responses.is_a?(Hash) && !responses.empty?) ? "continuation" : nil
    end

    # The gem's own `InputRequiredResult`, or a plain Hash in the same wire shape, like
    # the TS SDK's `isInputRequiredShape`.
    sig { params(result: T.untyped).returns(T::Boolean) }
    def input_required?(result)
      return true if input_required_result?(result)
      return false unless result.is_a?(Hash)

      (result[:resultType] || result["resultType"]) == "input_required"
    end

    # `MCP::Server::InputRequiredResult` only exists in newer mcp releases.
    sig { params(result: T.untyped).returns(T::Boolean) }
    def input_required_result?(result)
      !!(defined?(::MCP::Server::InputRequiredResult) && result.is_a?(::MCP::Server::InputRequiredResult))
    end

    # Deep copy of the Hash/Array structure (strings and other leaves are left shared;
    # nothing downstream edits a string in place). `copies` keeps a cyclic structure from
    # looping and keeps shared sub-objects shared in the copy.
    sig { params(value: T.untyped, copies: T::Hash[Integer, T.untyped]).returns(T.untyped) }
    def own_copy(value, copies = {})
      case value
      when Hash
        copies.fetch(value.object_id) do
          copy = copies[value.object_id] = {}
          value.each { |key, item| copy[key] = own_copy(item, copies) }
          copy
        end
      when Array
        copies.fetch(value.object_id) do
          copy = copies[value.object_id] = []
          value.each { |item| copy << own_copy(item, copies) }
          copy
        end
      else
        value
      end
    end

    sig { params(result: T.untyped).returns(T::Boolean) }
    def error_result?(result)
      return result.error? if mcp_response?(result)
      return !!(result[:isError] || result["isError"]) if result.is_a?(Hash)

      false
    end
  end
end
