require_relative "test_helper"

# A tool defined after `AgentCat.track()` was called still gets AgentCat's parameters and
# interception — the sync runs again right before any request that needs it: every
# `tools/list`, and any `tools/call` naming a tool not yet wrapped (covering a server
# instance whose very first request is a direct call, with no `tools/list` before it).
class DynamicToolRegistrationTest < Minitest::Test
  include AgentCatTestHelpers

  def define_late_tool(server, name: "late")
    server.define_tool(name: name, description: "Registered after track", input_schema: {type: "object", properties: {msg: {type: "string"}}, required: ["msg"]}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}])
    end
  end

  def test_a_tool_defined_after_track_is_instrumented_once_listed
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    define_late_tool(server)

    listed = listed_tool(server, "late")
    assert listed[:inputSchema][:properties].key?(:session_id), "expected session_id to be injected after a tools/list"
    assert listed[:inputSchema][:properties].key?(:context)

    result = tool_result(server, "late", {msg: "hello"})
    meta = agentcat_meta(result)

    assert_equal [mint_back_issued_text(meta[:session_id]), "hello"], texts_of(result)
    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal "late", client.last_event[:resource_name]
  end

  def test_a_tool_defined_after_track_is_instrumented_on_a_direct_call_with_no_prior_list
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    define_late_tool(server)

    # No tools/list happened yet — `call_tool` (not `list_tools`) is the trigger here.
    result = tool_result(server, "late", {msg: "hello"})
    meta = agentcat_meta(result)

    assert_equal [mint_back_issued_text(meta[:session_id]), "hello"], texts_of(result)
    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal "late", client.last_event[:resource_name]
  end

  def test_calling_an_unknown_tool_name_does_not_raise
    server = build_server
    track(server, project_id: PROJECT_ID)

    result = call_tool(server, "does-not-exist", {})

    assert result[:error], "expected the usual tool-not-found error, not a crash"
  end

  # The scenario the fix targets: a host that builds a fresh `MCP::Server` per request and
  # calls `AgentCat.track` on each one. A client that already knows a tool's name — because
  # it listed tools against an earlier instance — can call it on a brand new instance
  # without ever listing on that instance first. `echo` (present at construction) is already
  # covered by `install!`'s own synchronous pass regardless of this fix; `late` (registered
  # after `track()`, on this specific instance) is the part that needs it.
  def test_a_fresh_per_request_server_instance_instruments_a_direct_first_call
    first_instance = build_server
    track(first_instance, project_id: PROJECT_ID)
    list_tools(first_instance) # the client's earlier discovery, on a different instance

    second_instance = build_server
    client = track(second_instance, project_id: PROJECT_ID)
    define_late_tool(second_instance)

    result = tool_result(second_instance, "late", {msg: "hello"})
    meta = agentcat_meta(result)

    assert AgentCat::SessionManager.valid?(meta[:session_id])
    assert_equal "late", client.last_event[:resource_name]
  end

  def test_listing_twice_does_not_re_instrument_or_duplicate_parameters
    server = build_server
    track(server, project_id: PROJECT_ID)
    define_late_tool(server)

    list_tools(server)
    first_properties = listed_tool(server, "late")[:inputSchema][:properties].keys
    list_tools(server)
    second_properties = listed_tool(server, "late")[:inputSchema][:properties].keys

    assert_equal first_properties.sort, second_properties.sort
  end

  def test_tools_already_present_at_track_time_are_unaffected
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    list_tools(server)
    tool_result(server, "echo", {msg: "hello"})

    assert AgentCat::SessionManager.valid?(client.last_event[:session_id])
  end

  def test_handle_json_entry_point_also_picks_up_late_tools
    server = build_server
    track(server, project_id: PROJECT_ID)
    define_late_tool(server)

    request = JSON.generate({jsonrpc: "2.0", id: 1, method: "tools/list", params: {}})
    response = JSON.parse(server.handle_json(request))
    late = response["result"]["tools"].find { |tool| tool["name"] == "late" }

    assert late["inputSchema"]["properties"].key?("session_id")
  end
end
