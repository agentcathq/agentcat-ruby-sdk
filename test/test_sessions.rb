require_relative "test_helper"

class SessionsTest < Minitest::Test
  include AgentCatTestHelpers

  def test_mints_a_session_when_the_agent_sends_none
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello"})
    meta = agentcat_meta(result)

    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal [mint_back_issued_text(meta[:session_id]), "hello"], texts_of(result)
    assert_equal meta[:session_id], client.last_event[:session_id]
  end

  def test_valid_session_id_passes_through_untouched
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    session_id = AgentCat::SessionManager.mint_session_id

    result = tool_result(server, "echo", {msg: "hello", session_id: session_id})

    assert_equal ["hello"], texts_of(result)
    refute result.key?(:_meta)
    assert_equal session_id, client.last_event[:session_id]
  end

  # `session_id`'s schema `pattern` (`^(start|ses_[0-9A-Za-z]{27})$`) means the `mcp` gem's
  # own argument validation rejects a malformed session_id *before* AgentCat's interceptor
  # runs, and the tool handler never runs. The call is still recorded as a rejected call
  # : one error event, and the "unrecognized" block ahead of the gem's error.
  def test_malformed_session_id_is_rejected_by_the_schema_before_agentcat_runs
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello", session_id: "not-a-real-id"})

    assert result[:isError]
    assert_equal mint_back_unrecognized_text, texts_of(result).first
    assert_match(/does not match pattern/, texts_of(result).last)
    assert_equal 1, client.events.size
    event = client.last_event
    assert event[:is_error]
    assert_nil event[:session_id]
    assert_equal "invalid", event[:tags]["agentcat_session_id_source"]
  end

  # `Interceptor#resolve_session`'s `:invalid` branch still exists and still matters for any
  # dispatch path that doesn't enforce the schema `pattern` up front (a direct `ToolHandle`
  # call, like this one, or a host with `validate_tool_call_arguments` turned off).
  def test_invalid_session_id_is_rejected_without_a_replacement_on_a_direct_call
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    response = server.tools["echo"].call(msg: "hello", session_id: "not-a-real-id")
    meta = response.meta&.dig(:agentcat)
    AgentCat.flush(timeout: 1)

    assert_equal [mint_back_unrecognized_text, "hello"], response.content.map { |block| block[:text] }
    assert_nil meta[:session_id]
    assert_nil client.last_event.fetch(:session_id)
    assert_equal "not-a-real-id", client.last_event[:parameters]["arguments"]["session_id"]
  end

  def test_start_sentinel_mints_like_an_absent_session_id
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello", session_id: "start"})
    meta = agentcat_meta(result)

    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal meta[:session_id], client.last_event[:session_id]
  end

  # The schema `pattern` only recognizes a lowercase, unpadded `"start"` — case and
  # whitespace tolerance is `SessionManager.start_sentinel?`'s own leniency, unreachable
  # through the standard path once the `mcp` gem's schema validation is in front of it.
  # Still real, still worth keeping, for the same non-standard-dispatch reasons as above.
  def test_start_sentinel_variants_are_still_tolerated_on_a_direct_call
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    ["Start", "  START  "].each do |sentinel|
      response = server.tools["echo"].call(msg: "hello", session_id: sentinel)
      meta = response.meta&.dig(:agentcat)
      AgentCat.flush(timeout: 1)

      assert AgentCat::SessionManager.valid?(meta[:session_id])
      assert_equal meta[:session_id], client.last_event[:session_id]
    end
  end

  def test_session_resolution_matrix
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    valid_session = AgentCat::SessionManager.mint_session_id
    valid_result = tool_result(server, "echo", {msg: "valid", session_id: valid_session})
    assert_equal valid_session, client.events.last[:session_id]
    assert_equal valid_session, agentcat_meta(valid_result)[:session_id] if agentcat_meta(valid_result)

    # Goes through the ToolHandle directly, not tool_result: a malformed session_id now
    # fails the schema `pattern` before Interceptor#resolve_session's :invalid branch ever
    # runs on the standard tools/call path (see the two tests dedicated to that above).
    server.tools["echo"].call(msg: "invalid", session_id: "not-a-real-id")
    AgentCat.flush(timeout: 1)
    assert_nil client.events.last.fetch(:session_id)
    assert_equal "not-a-real-id", client.events.last[:parameters]["arguments"]["session_id"]

    minted_result = tool_result(server, "echo", {msg: "new"})
    minted_meta = agentcat_meta(minted_result)
    assert AgentCat::SessionManager.valid?(minted_meta[:session_id])

    server = build_server
    resolver = ->(tool_call) { "host-#{tool_call.arguments["msg"]}" }
    host_client = track(server, project_id: PROJECT_ID, resolve_session_id: resolver)
    refute listed_tool(server, "echo")[:inputSchema][:properties].key?(:session_id)
    host_result = tool_result(server, "echo", {msg: "hosted"})
    # The host's correlation id maps onto a stable ses_ KSUID (SHA-256 derivation,
    # pinned to the Go SDK in test_session_manager.rb golden vectors).
    assert_equal "ses_2bTbnEB4R6WGc8cMqqWleL2Nili", host_client.events.last[:session_id]
    assert_nil agentcat_meta(host_result)
  end

  def test_structured_content_and_error_flag_are_preserved_on_mint_back
    tool = echo_tool(output_schema: {type: "object", properties: {echo: {type: "string"}}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {echo: msg}, error: true)
    end
    server = build_server(tools: [tool])
    track(server)

    result = tool_result(server, "echo", {msg: "hello"})
    session_id = agentcat_meta(result)[:session_id]

    assert_equal({echo: "hello", mcp_session: {session_id: session_id, status: "issued"}}, result[:structuredContent])
    assert result[:isError]
    assert session_id
  end

  def test_structured_content_is_not_added_for_tools_without_an_output_schema
    server = build_server
    track(server, project_id: PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello"})

    refute result.key?(:structuredContent)
    assert agentcat_meta(result)[:session_id]
  end

  def test_hash_results_are_annotated_too
    tool = echo_tool { |msg:, **| {content: [{type: "text", text: msg}]} }
    server = build_server(tools: [tool])
    track(server)

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal 2, result[:content].size
    assert AgentCat::SessionManager.valid?(agentcat_meta(result)[:session_id])
  end

  def test_host_resolved_sessions_suppress_injection_and_are_reported
    server = build_server
    resolver = ->(tool_call) { "host-#{tool_call.arguments["msg"]}" }
    client = track(server, project_id: PROJECT_ID, resolve_session_id: resolver)

    refute listed_tool(server, "echo")[:inputSchema][:properties].key?(:session_id)

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal ["hello"], texts_of(result)
    refute result.key?(:_meta)
    # Derived deterministically from the host correlation id "host-hello" (golden
    # vector pinned to the Go SDK), never reported verbatim.
    assert_equal "ses_2brEm6m7DoKUNNy6eirTf6ARaxy", client.last_event[:session_id]
  end

  def test_failing_host_resolver_mints_a_fallback_session_instead_of_going_sessionless
    server = build_server
    client = track(server, project_id: PROJECT_ID, resolve_session_id: ->(*) { raise "boom" })

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal ["hello"], texts_of(result)
    assert AgentCat::SessionManager.valid?(client.last_event[:session_id])
    # still hook mode: no mint-back shown, no session_id in the schema either
    assert_nil agentcat_meta(result)
  end

  def test_blank_host_resolver_mints_a_fallback_session_instead_of_going_sessionless
    server = build_server
    client = track(server, project_id: PROJECT_ID, resolve_session_id: ->(*) { "" })

    tool_result(server, "echo", {msg: "hello"})

    assert AgentCat::SessionManager.valid?(client.last_event[:session_id])
  end

  def test_host_resolver_derives_a_stable_session_across_calls
    server = build_server
    resolver = ->(tool_call) { "chat-#{tool_call.arguments["msg"]}" }
    client = track(server, project_id: PROJECT_ID, resolve_session_id: resolver)

    first = tool_result(server, "echo", {msg: "12345"})
    second = tool_result(server, "echo", {msg: "12345"})
    tool_result(server, "echo", {msg: "99999"})

    assert_equal client.events[-3][:session_id], client.events[-2][:session_id]
    assert AgentCat::SessionManager.valid?(client.events[-1][:session_id])
    refute_equal client.events[-2][:session_id], client.events[-1][:session_id]
    assert_nil agentcat_meta(first)
    assert_nil agentcat_meta(second)
  end

  def test_host_resolver_trims_whitespace_before_deriving
    server = build_server
    client = track(server, project_id: PROJECT_ID, resolve_session_id: ->(*_) { "  hosted-id\t" })

    tool_result(server, "echo", {msg: "hello"})

    # "hosted-id" with default project, via derive_session_id(nil project boundary)
    assert_equal AgentCat::SessionManager.derive_session_id("hosted-id", PROJECT_ID), client.last_event[:session_id]
  end

  def test_symbol_keyed_arguments_are_recognised_on_direct_calls
    server = build_server
    track(server)
    session_id = AgentCat::SessionManager.mint_session_id

    response = server.tools["echo"].call(msg: "hi", session_id: session_id)

    assert_equal 1, response.content.size
  end

  # --- mcp_session mirror beyond mint/invalid ---

  def test_supplied_session_mirrors_as_active_with_no_text_block
    output_tool = echo_tool(output_schema: {type: "object", properties: {}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {})
    end
    server = build_server(tools: [output_tool])
    track(server, project_id: PROJECT_ID)
    session_id = AgentCat::SessionManager.mint_session_id

    result = tool_result(server, "echo", {msg: "hello", session_id: session_id})

    assert_equal ["hello"], texts_of(result)
    refute result.key?(:_meta)
    assert_equal({session_id: session_id, status: "active"}, result[:structuredContent][:mcp_session])
  end

  def test_supplied_session_mirrors_agent_id_when_tracking_is_enabled
    output_tool = echo_tool(output_schema: {type: "object", properties: {}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {})
    end
    server = build_server(tools: [output_tool])
    track(server, project_id: PROJECT_ID, enable_agent_tracking: true)
    session_id = AgentCat::SessionManager.mint_session_id

    result = tool_result(server, "echo", {msg: "hi", session_id: session_id, agent_id: "agent-1"})

    assert_equal({session_id: session_id, agent_id: "agent-1", status: "active"}, result[:structuredContent][:mcp_session])
  end

  def test_hook_mode_mirrors_agent_id_only_with_no_status
    output_tool = echo_tool(output_schema: {type: "object", properties: {}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {})
    end
    server = build_server(tools: [output_tool])
    track(server, project_id: PROJECT_ID, resolve_session_id: ->(*) { "host-correlation" }, enable_agent_tracking: true)

    result = tool_result(server, "echo", {msg: "hi", agent_id: "agent-1"})

    assert_equal(["hi"], texts_of(result))
    refute result.key?(:_meta)
    assert_equal({agent_id: "agent-1"}, result[:structuredContent][:mcp_session])
  end

  def test_hook_mode_with_no_agent_id_adds_no_mirror_at_all
    output_tool = echo_tool(output_schema: {type: "object", properties: {}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {})
    end
    server = build_server(tools: [output_tool])
    track(server, project_id: PROJECT_ID, resolve_session_id: ->(*) { "host-correlation" })

    result = tool_result(server, "echo", {msg: "hi"})

    refute result[:structuredContent].key?(:mcp_session)
  end

  def test_foreign_session_mirrors_agent_id_only_when_present
    owning_tool = MCP::Tool.define(
      name: "owner",
      output_schema: {type: "object", properties: {}},
      input_schema: {type: "object", properties: {session_id: {type: "string"}}, required: ["session_id"]}
    ) { |session_id:, **| MCP::Tool::Response.new([{type: "text", text: session_id}], structured_content: {}) }
    server = build_server(tools: [owning_tool])
    track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    result = tool_result(server, "owner", {session_id: "host-owned", agent_id: "agent-1"})

    assert_equal({agent_id: "agent-1"}, result[:structuredContent][:mcp_session])
  end
end
