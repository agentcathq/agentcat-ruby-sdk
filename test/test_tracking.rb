require_relative "test_helper"
require "json"

class TrackingTest < Minitest::Test
  include AgentCatTestHelpers

  def test_injects_context_and_session_id_into_every_tool_schema
    server = build_server
    track(server)

    properties = listed_tool(server, "echo")[:inputSchema][:properties]

    assert_equal AgentCat::Schema::CONTEXT_DESCRIPTION, properties.dig(:context, :description)
    assert_equal "string", properties.dig(:context, :type)
    assert_equal AgentCat::Schema::SESSION_ID_DESCRIPTION, properties.dig(:session_id, :description)
    assert_equal AgentCat::Schema::SESSION_ID_PATTERN, properties.dig(:session_id, :pattern)
    assert_equal "string", properties.dig(:msg, :type)
    assert_equal ["msg", "session_id", "context"], listed_tool(server, "echo")[:inputSchema][:required]
  end

  # The event's response shares content blocks with what the agent gets. Truncating the
  # event's copy in the background must not cut the agent's own text to 32KB.
  def test_background_truncation_does_not_touch_the_agents_result
    big = echo_tool(name: "big") { |**| MCP::Tool::Response.new([{type: "text", text: "a" * 40_000}]) }
    server = build_server(tools: [big])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "big", {msg: "x", session_id: "start"})

    assert_equal 40_000, result[:content].last[:text].bytesize
    assert_equal AgentCat::PayloadLimits::MAX_CONTENT_TEXT_LENGTH + 3, client.last_event[:response][:content].last[:text].bytesize
  end

  def test_a_redact_event_hook_editing_the_response_in_place_does_not_reach_the_agent
    tool = echo_tool { |**| {content: [{type: "text", text: "secret"}]} }
    server = build_server(tools: [tool])
    hook = ->(event) {
      event.response[:content].first[:text] = "[gone]"
      event
    }
    client = track(server, project_id: PROJECT_ID, redact_event: hook)

    result = tool_result(server, "echo", {msg: "x", session_id: "start"})

    assert_equal "secret", result[:content].last[:text]
    assert_equal "[gone]", client.last_event[:response][:content].first[:text]
  end

  # The agent gets the mint-back (session_id text block, `mcp_session` mirror); the event
  # records only what the tool itself returned, same as the TS SDK.
  def test_event_response_is_the_tools_own_result_without_the_mint_back
    tool = echo_tool(output_schema: {type: "object", properties: {msg: {type: "string"}}}) do |msg:, server_context: nil|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {msg: msg})
    end
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hi", session_id: "start"})

    assert_match(/\A\[session_id issued/, result[:content].first[:text])
    assert result[:structuredContent].key?(:mcp_session)

    response = client.last_event[:response]
    assert_equal [{type: "text", text: "hi"}], response[:content]
    assert_equal({msg: "hi"}, response[:structuredContent])
  end

  # Same order and requiredness as the Go/TS SDKs: handles first, then context.
  def test_injection_order_matches_the_reference_sdks_with_agent_tracking
    server = build_server
    track(server, enable_agent_tracking: true)

    schema = listed_tool(server, "echo")[:inputSchema]

    assert_equal %i[msg session_id agent_id context], schema[:properties].keys
    assert_equal %w[msg session_id agent_id context], schema[:required]
  end

  # Required is soft: the schema asks for all three, but a call without them still runs
  # and still publishes - the `mcp` gem's own required check doesn't get to bounce it.
  def test_a_call_without_the_injected_parameters_still_runs
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    response = server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "echo", arguments: {msg: "hi"}}})
    AgentCat.flush(timeout: 1)

    refute response[:result][:isError]
    event = client.last_event
    assert_equal "minted", event[:tags]["agentcat_session_id_source"]
    assert_nil event[:user_intent]
    assert_equal({"msg" => "hi"}, event[:parameters]["arguments"])
  end

  # The tool's own required fields are still enforced as before.
  def test_the_tools_own_required_fields_are_still_enforced
    server = build_server
    track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    response = server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "echo", arguments: {}}})

    assert response[:result][:isError]
    assert_match(/Missing required arguments: msg\z/, response[:result][:content].last[:text])
  end

  # With `validate_tool_call_arguments` the gem runs full JSON Schema validation too;
  # a missing injected parameter must not fail that either.
  def test_full_schema_validation_tolerates_missing_injected_parameters
    configuration = MCP::Configuration.new(validate_tool_call_arguments: true)
    server = MCP::Server.new(name: "test", tools: [echo_tool], configuration: configuration)
    track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    response = server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "echo", arguments: {msg: "hi"}}})

    refute response[:result][:isError], response[:result][:content].inspect
  end

  def test_preserves_tool_metadata_when_listing
    tool = echo_tool(title: "Echo!", annotations: {read_only_hint: true}, meta: {owner: "tests"})
    server = build_server(tools: [tool])
    track(server)

    listed = listed_tool(server, "echo")

    assert_equal "Echo a message", listed[:description]
    assert_equal "Echo!", listed[:title]
    assert_equal true, listed.dig(:annotations, :readOnlyHint)
    assert_equal({owner: "tests"}, listed[:_meta])
  end

  def test_strips_injected_parameters_before_calling_tool
    received = nil
    tool = echo_tool do |**arguments|
      received = arguments.except(:server_context)
      MCP::Tool::Response.new([{type: "text", text: arguments[:msg]}])
    end
    server = build_server(tools: [tool])
    track(server)

    result = tool_result(server, "echo", {msg: "hello", context: "testing", session_id: AgentCat::SessionManager.mint_session_id})

    assert_equal({msg: "hello"}, received)
    assert_equal "hello", texts_of(result).first
  end

  def test_tool_that_only_declares_its_own_keywords_still_works
    # The default echo tool only accepts `msg:`; without stripping the call would raise ArgumentError.
    server = build_server
    track(server)
    session_id = AgentCat::SessionManager.mint_session_id

    result = tool_result(server, "echo", {msg: "hello", context: "why", session_id: session_id})

    assert_equal ["hello"], texts_of(result)
  end

  def test_passes_server_context_through_to_the_tool
    seen = nil
    tool = echo_tool do |msg:, server_context: nil|
      seen = server_context
      MCP::Tool::Response.new([{type: "text", text: msg}])
    end
    server = build_server(tools: [tool])
    track(server)

    tool_result(server, "echo", {msg: "hi"})

    assert_kind_of MCP::ServerContext, seen
  end

  def test_agent_id_is_injected_and_reported_when_agent_tracking_is_enabled
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    assert listed_tool(server, "echo")[:inputSchema][:properties].key?(:agent_id)

    tool_result(server, "echo", {msg: "hi", agent_id: "agent-42"})

    assert_equal "agent-42", client.last_event[:actor_id]
    refute client.last_event[:parameters]["arguments"].key?("server_context")
  end

  def test_agent_id_is_not_injected_by_default
    server = build_server
    track(server)

    refute listed_tool(server, "echo")[:inputSchema][:properties].key?(:agent_id)
  end

  def test_missing_required_arguments_are_still_rejected_by_the_server
    server = build_server
    track(server)

    result = tool_result(server, "echo", {context: "no msg"})

    assert result[:isError]
    assert_match(/Missing required arguments: msg/, texts_of(result).last)
  end

  def test_handle_can_be_called_directly_with_keyword_arguments
    server = build_server
    track(server)

    # A pre-existing, valid session_id keeps this call mint-back-free, so the tool's own
    # content is the only block in the response.
    session_id = AgentCat::SessionManager.mint_session_id
    response = server.tools["echo"].call(msg: "direct", context: "test", session_id: session_id)

    assert_kind_of MCP::Tool::Response, response
    assert_equal "direct", response.content.first[:text]
  end

  def test_every_event_carries_a_unique_evt_prefixed_id
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "one", context: "testing"})
    tool_result(server, "echo", {msg: "two", context: "testing"})

    ids = client.events.map { |event| event[:id] }
    assert(ids.all? { |id| id.match?(/\Aevt_[0-9A-Za-z]{27}\z/) })
    assert_equal 2, ids.uniq.size
  end

  def test_sanitizes_image_content_blocks_in_the_published_event
    tool = echo_tool(name: "image", input_schema: {type: "object", properties: {}}) do |_context = nil, **_|
      MCP::Tool::Response.new([{type: "image", data: "abc", mimeType: "image/png"}])
    end
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "image", {context: "why"})

    assert_equal(
      {type: "text", text: AgentCat::Sanitization::IMAGE_REDACTED},
      client.last_event[:response][:content].last
    )
  end

  def test_sanitizes_large_base64_parameters_in_the_published_event
    tool = echo_tool(name: "blobby", input_schema: {type: "object", properties: {}}) do |_context = nil, **_|
      MCP::Tool::Response.new([{type: "text", text: "ok"}])
    end
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "blobby", {context: "why", blob: "A" * 12_000})

    assert_equal AgentCat::Sanitization::BINARY_DATA_REDACTED, client.last_event[:parameters]["arguments"]["blob"]
  end

  def test_truncates_oversized_response_text_in_the_published_event
    tool = echo_tool(name: "huge", input_schema: {type: "object", properties: {}}) do |_context = nil, **_|
      MCP::Tool::Response.new([{type: "text", text: "-" * 40_000}])
    end
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "huge", {context: "why"})

    text = client.last_event[:response][:content].last[:text]
    # TS parity: the limit counts the kept text, the "..." suffix goes on top.
    assert_equal AgentCat::PayloadLimits::MAX_CONTENT_TEXT_LENGTH + 3, text.bytesize
    assert text.end_with?(AgentCat::PayloadLimits::TRUNCATION_SUFFIX)
  end

  def test_huge_events_fit_the_byte_budget
    tool = echo_tool(name: "pass", input_schema: {type: "object", properties: {}}) do |_context = nil, **_|
      MCP::Tool::Response.new([{type: "text", text: "ok"}])
    end
    server = build_server(tools: [tool])
    client = track(server, project_id: PROJECT_ID)

    parameters = Array.new(20) { |i| ["s#{i}", "-" * 100_000] }.to_h
    tool_result(server, "pass", {msg: "hi", context: "why", **parameters})

    assert_operator JSON.generate(client.last_event).bytesize, :<=, AgentCat::PayloadLimits::MAX_EVENT_BYTES
  end

  # --- connecting client identity (clientInfo from the initialize handshake) ---

  def test_captures_client_name_and_version_from_server_context
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    fake_context = Struct.new(:client_info).new({name: "Claude Desktop", version: "1.2.3"})
    session_id = AgentCat::SessionManager.mint_session_id

    server.tools["echo"].call(msg: "hi", session_id: session_id, server_context: fake_context)
    AgentCat.flush(timeout: 1)

    assert_equal "Claude Desktop", client.last_event[:client_name]
    assert_equal "1.2.3", client.last_event[:client_version]
  end

  def test_client_identity_is_absent_when_the_context_does_not_expose_it
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    session_id = AgentCat::SessionManager.mint_session_id

    server.tools["echo"].call(msg: "hi", session_id: session_id, server_context: Object.new)
    AgentCat.flush(timeout: 1)

    refute client.last_event.key?(:client_name)
    refute client.last_event.key?(:client_version)
  end

  def test_client_identity_is_absent_when_the_client_declined_to_identify_itself
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    fake_context = Struct.new(:client_info).new(nil)
    session_id = AgentCat::SessionManager.mint_session_id

    server.tools["echo"].call(msg: "hi", session_id: session_id, server_context: fake_context)
    AgentCat.flush(timeout: 1)

    refute client.last_event.key?(:client_name)
  end

  # A stateless HTTP request that carries only `clientInfo` in `_meta` (no full 2026
  # envelope triple) is not classified as modern by the `mcp` gem, so
  # `server_context.client_info` is nil. The identity is still right there in `_meta`,
  # which is where the Go/TS SDKs read it, and where we must too.
  def test_captures_client_identity_from_meta_on_a_stateless_request
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    call_tool_with_meta(
      server, "echo", {msg: "hi", session_id: "start"},
      {"io.modelcontextprotocol/clientInfo" => {"name" => "Claude Code", "version" => "0.9.0"}}
    )
    AgentCat.flush(timeout: 1)

    assert_equal "Claude Code", client.last_event[:client_name]
    assert_equal "0.9.0", client.last_event[:client_version]
  end

  def test_captures_client_identity_and_protocol_version_from_the_modern_envelope
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    call_tool_with_meta(
      server, "echo", {msg: "hi", session_id: "start"},
      {
        "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {"name" => "Codex", "version" => "2.0"}
      }
    )
    AgentCat.flush(timeout: 1)

    assert_equal "Codex", client.last_event[:client_name]
    assert_equal "2.0", client.last_event[:client_version]
    assert_equal "2026-07-28", client.last_event[:tags]["agentcat_protocol_version"]
  end

  def test_protocol_version_tag_is_absent_when_the_request_declares_none
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi", session_id: "start"})

    refute_includes client.last_event[:tags], "agentcat_protocol_version"
  end

  # The reference SDKs attach the incoming HTTP headers to the event at
  # `parameters.extra.requestInfo.headers`, so AgentCat can tell which client called
  # (User-Agent and friends) even when `_meta` carries no identity. The transport hook
  # makes them ambient; the interceptor has to fold them into the published event.
  def test_http_request_headers_are_attached_to_the_published_event
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    extra = {"requestInfo" => {"headers" => {"user-agent" => "Claude Code", "content-type" => "application/json"}}}

    previous = AgentCat::RequestContext.capture(extra)
    begin
      tool_result(server, "echo", {msg: "hi", session_id: "start"})
    ensure
      AgentCat::RequestContext.restore(previous)
    end

    assert_equal({"requestId" => 2}.merge(extra), client.last_event[:parameters]["extra"])
    # The raw, unstripped arguments ride alongside under their own key.
    assert_equal "hi", client.last_event[:parameters]["arguments"]["msg"]
  end

  # `requestId` (the JSON-RPC id of the `tools/call`) is always there, so
  # stdio gets an `extra` too. No headers means no `requestInfo` and no `sessionId`.
  def test_event_parameters_carry_the_request_id_outside_an_http_request
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi", session_id: "start"})

    assert_equal({"requestId" => 2}, client.last_event[:parameters]["extra"])
  end

  def test_a_string_request_id_is_kept_as_sent
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    server.handle({jsonrpc: "2.0", id: "req-7", method: "tools/call", params: {name: "echo", arguments: {msg: "hi", session_id: "start"}}})
    AgentCat.flush(timeout: 1)

    assert_equal "req-7", client.last_event[:parameters].dig("extra", "requestId")
  end

  # `_meta` isn't an HTTP thing, so it shows up in `extra` on stdio too, as the client
  # sent it.
  def test_request_meta_lands_in_extra_without_an_http_request
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    call_tool_with_meta(server, "echo", {msg: "hi", session_id: "start"}, {"progressToken" => 3, "claudecode/toolUseId" => "toolu_abc"})
    AgentCat.flush(timeout: 1)

    extra = client.last_event[:parameters]["extra"]
    assert_equal({"requestId" => 2, "_meta" => {"progressToken" => 3, "claudecode/toolUseId" => "toolu_abc"}}, extra)
  end

  # The `mcp` gem has no auth of its own. A host that puts the request's auth into
  # `server_context` (`auth_info:`) gets it on the event, as `extra.authInfo`.
  def test_auth_info_from_server_context_lands_in_extra
    server = MCP::Server.new(name: "auth-server", version: "1.0.0", tools: [echo_tool],
      server_context: {auth_info: {"clientId" => "client-1", "scopes" => ["read"]}})
    client = track(server, project_id: PROJECT_ID)

    tool_result(server, "echo", {msg: "hi", session_id: "start"})

    assert_equal({"clientId" => "client-1", "scopes" => ["read"]}, client.last_event[:parameters].dig("extra", "authInfo"))
  end

  # Key order: sessionId, requestId, _meta, requestInfo, authInfo. No `method` key.
  def test_extra_keys_follow_the_d34_order
    server = MCP::Server.new(name: "auth-server", version: "1.0.0", tools: [echo_tool],
      server_context: {authInfo: {"clientId" => "client-1"}})
    client = track(server, project_id: PROJECT_ID)
    captured = {"requestInfo" => {"headers" => {"mcp-session-id" => "sess-1"}, "url" => "http://localhost/mcp"}}

    previous = AgentCat::RequestContext.capture(captured)
    begin
      call_tool_with_meta(server, "echo", {msg: "hi", session_id: "start"}, {"progressToken" => 3})
      AgentCat.flush(timeout: 1)
    ensure
      AgentCat::RequestContext.restore(previous)
    end

    extra = client.last_event[:parameters]["extra"]
    assert_equal %w[sessionId requestId _meta requestInfo authInfo], extra.keys
    assert_equal "sess-1", extra["sessionId"]
    refute extra.key?("method")
  end

  # `extra` is the SDK's key, but the tool's own arguments live under `arguments`, so a
  # tool that happens to declare an `extra` argument keeps it and the headers stay too.
  def test_a_tool_argument_named_extra_does_not_collide_with_the_sdk_extra
    extra_tool = echo_tool(name: "extra_tool", input_schema: {type: "object", properties: {extra: {type: "string"}}, required: []}) do |server_context: nil, **arguments|
      MCP::Tool::Response.new([{type: "text", text: arguments[:extra].to_s}])
    end
    server = build_server(tools: [extra_tool])
    client = track(server, project_id: PROJECT_ID)
    captured = {"requestInfo" => {"headers" => {"user-agent" => "curl/8"}}}

    previous = AgentCat::RequestContext.capture(captured)
    begin
      tool_result(server, "extra_tool", {extra: "agent-supplied"})
    ensure
      AgentCat::RequestContext.restore(previous)
    end

    assert_equal({"requestId" => 2}.merge(captured), client.last_event[:parameters]["extra"])
    assert_equal "agent-supplied", client.last_event[:parameters]["arguments"]["extra"]
  end

  # `call_fn_for` (the Official adapter) picks between two lambdas depending on whether the
  # native tool's `call` accepts `server_context:` — every other test's tool declares it (or
  # `**`), so only that branch ever actually runs. A tool with a strict signature like this
  # one is what exercises the other lambda, the one that calls the original without it.
  def test_a_tool_whose_call_does_not_accept_server_context_still_works
    strict_tool = MCP::Tool.define(
      name: "strict",
      description: "Only accepts its own declared parameter",
      input_schema: {type: "object", properties: {msg: {type: "string"}}, required: ["msg"]}
    ) { |msg:| MCP::Tool::Response.new([{type: "text", text: msg}]) }
    server = build_server(tools: [strict_tool])
    track(server)

    result = tool_result(server, "strict", {msg: "hi"})

    assert_equal "hi", texts_of(result).last
  end

  # --- mcp_session output schema declaration ---

  def test_declares_mcp_session_on_tools_with_an_output_schema
    tool = echo_tool(output_schema: {type: "object", properties: {echo: {type: "string"}}})
    server = build_server(tools: [tool])
    track(server)

    schema = listed_tool(server, "echo")[:outputSchema]
    mcp_session = schema.dig(:properties, :mcp_session)

    assert_equal "object", mcp_session[:type]
    assert_equal AgentCat::Schema::MCP_SESSION_FIELD_DESCRIPTION, mcp_session[:description]
    assert_equal %i[session_id agent_id status], mcp_session[:properties].keys
    assert schema.dig(:properties, :echo), "the tool's own output property should survive"
  end

  def test_does_not_declare_mcp_session_when_the_tool_has_no_output_schema
    server = build_server
    track(server)

    refute listed_tool(server, "echo").key?(:outputSchema)
  end

  def test_hook_mode_output_schema_omits_status_and_session_id
    tool = echo_tool(output_schema: {type: "object", properties: {}})
    server = build_server(tools: [tool])
    track(server, resolve_session_id: ->(*) { "x" })

    mcp_session = listed_tool(server, "echo")[:outputSchema].dig(:properties, :mcp_session)

    assert_equal AgentCat::Schema::MCP_SESSION_FIELD_DESCRIPTION_HOOK_MODE, mcp_session[:description]
    assert_equal [:agent_id], mcp_session[:properties].keys
  end

  # `mint_back` rebuilds the response object; a bug there must never turn a successful
  # tool call into a failed one. Built directly rather than through `track`/`tool_result`
  # because the broken `meta` below would also break the real MCP::Server's own
  # serialization of the result - this isolates "does AgentCat's own annotation step
  # fail safely" from "can the mcp gem serialize a deliberately broken response".
  def test_a_failure_inside_mint_back_falls_back_to_the_original_result
    tracker = AgentCat::Tracker.new(
      adapter: AgentCat::Adapters::Official.new(MCP::Server.new(name: "x", version: "1")),
      project_id: nil,
      options: AgentCat::Options.new
    )
    handle = AgentCat::ToolHandle.new(name: "t", call_fn: ->(*) {}, input_schema: {}, output_schema: nil)
    interceptor = AgentCat::Interceptor.new(handle: handle, tracker: tracker)

    weird_result = MCP::Tool::Response.new([{type: "text", text: "hello"}])
    def weird_result.meta
      "not-a-hash" # breaks `meta.merge(agentcat: annotation)` inside annotated_response
    end
    session = AgentCat::Interceptor::Session.new(AgentCat::SessionManager.mint_session_id, :minted)

    fallback = interceptor.send(:safe_mint_back, weird_result, session, {})

    assert_same weird_result, fallback
  end
end
