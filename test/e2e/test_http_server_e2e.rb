require_relative "e2e_helper"

# Runs the exact scenarios the in-process suite covers, but over a real Puma HTTP server and
# genuine `Net::HTTP` requests — the real `mcp` gem dispatch/schema-validation stack in
# front of AgentCat, not the `server.handle(hash)` shortcut. This tier exists because that
# shortcut skips part of the `mcp` gem: its own required-argument enforcement runs ahead
# of AgentCat's interceptor, and none of the in-process tests sees that.
class HttpServerE2ETest < Minitest::Test
  include E2EHelpers

  def test_tools_list_shows_the_required_session_id_schema
    run_e2e_server do |client, _recording|
      response = client.list_tools
      echo = response[:result][:tools].find { |tool| tool[:name] == "echo" }

      assert_includes echo[:inputSchema][:required], "session_id"
      assert_equal AgentCat::Schema::SESSION_ID_PATTERN, echo[:inputSchema][:properties][:session_id][:pattern]
    end
  end

  # session_id is listed as required, but softly: the real `mcp` gem's required check
  # (which runs ahead of AgentCat) must let a call without it through, and the call
  # gets a fresh session minted, same as `start`. Same goes for context.
  def test_omitting_injected_parameters_still_runs_over_real_http
    run_e2e_server do |client, recording|
      response = client.call_tool("echo", {msg: "hi"})

      refute response[:result][:isError], response[:result][:content].inspect
      assert_match(/\[session_id issued/, response[:result][:content].first[:text])
      assert_equal "minted", recording.last_event[:tags]["agentcat_session_id_source"]
    end
  end

  # The request thread only enqueues the event; a worker builds and delivers it later.
  # A slow `redact_event` stretches that gap so a read that doesn't wait for the queue sees
  # nothing. The recording client in E2EHelpers waits, so every test here reads the event.
  def test_reads_wait_for_the_event_queue
    slow_redact = ->(event) {
      sleep 0.3
      event
    }
    run_e2e_server(redact_event: slow_redact) do |client, recording|
      client.call_tool("echo", {msg: "hi"})

      refute_nil recording.last_event
      assert_equal 1, recording.events.size
    end
  end

  def test_start_mints_a_session_with_prepended_instructions_over_real_http
    run_e2e_server do |client, recording|
      response = client.call_tool("echo", {msg: "hi", session_id: "start"})
      texts = response[:result][:content].map { |block| block[:text] }

      assert_match(/\[session_id issued/, texts.first)
      assert_equal "hi", texts.last
      assert AgentCat::SessionManager.valid?(recording.last_event[:session_id])
    end
  end

  def test_structured_content_carries_mcp_session_over_real_http
    output_tool = echo_tool(output_schema: {type: "object", properties: {echo: {type: "string"}}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {echo: msg})
    end

    run_e2e_server(tools: [output_tool]) do |client, _recording|
      response = client.call_tool("echo", {msg: "hi", session_id: "start"})
      structured = response[:result][:structuredContent]

      assert_equal "hi", structured[:echo]
      assert_equal "issued", structured[:mcp_session][:status]
      assert AgentCat::SessionManager.valid?(structured[:mcp_session][:session_id])
    end
  end

  def test_a_tool_owning_its_own_session_id_is_left_alone_over_real_http
    owning_tool = MCP::Tool.define(
      name: "owner",
      input_schema: {type: "object", properties: {session_id: {type: "string"}}, required: ["session_id"]}
    ) { |session_id:, **| MCP::Tool::Response.new([{type: "text", text: session_id}]) }

    run_e2e_server(tools: [owning_tool]) do |client, recording|
      response = client.call_tool("owner", {session_id: "host-owned-value"})

      assert_equal "host-owned-value", response[:result][:content].first[:text]
      assert_nil recording.last_event.fetch(:session_id)
      assert_equal "host-owned-value", recording.last_event[:parameters]["arguments"]["session_id"]
    end
  end

  def test_a_tool_registered_after_track_is_instrumented_over_real_http
    run_e2e_server do |client, recording, server|
      server.define_tool(name: "late", description: "late", input_schema: {type: "object", properties: {n: {type: "integer"}}, required: ["n"]}) do |n:, **|
        MCP::Tool::Response.new([{type: "text", text: "got #{n}"}])
      end

      client.list_tools # triggers AgentCat's before_dispatch resync
      response = client.call_tool("late", {n: 1, session_id: "start"})
      texts = response[:result][:content].map { |block| block[:text] }

      assert_includes texts, "got 1"
      assert_equal "late", recording.last_event[:resource_name]
      assert AgentCat::SessionManager.valid?(recording.last_event[:session_id])
    end
  end

  # The in-process `server.handle(hash)` shortcut never runs a real `initialize` handshake,
  # so this is the only tier that can see `clientInfo` actually reach a published event.
  def test_the_connecting_clients_identity_is_captured_from_the_real_handshake
    run_e2e_server do |client, recording|
      client.call_tool("echo", {msg: "hi", session_id: "start"})

      assert_equal "e2e-client", recording.last_event[:client_name]
      assert_equal "0.1.0", recording.last_event[:client_version]
    end
  end

  # Stateless: no `initialize` to read clientInfo from, so identity has to come from the
  # per-request `_meta`. The gem only lifts that into its envelope when the full 2026
  # triple is present; a clientInfo-only `_meta` reaches the event only because we read
  # `_meta` directly, the same ladder the Go/TS SDKs use.
  def test_stateless_client_identity_is_captured_from_request_meta_over_real_http
    run_e2e_server(initialize: false, stateless: true) do |client, recording|
      client.call_tool_with_meta(
        "echo", {msg: "hi", session_id: "start"},
        {"io.modelcontextprotocol/clientInfo" => {"name" => "Codex", "version" => "3.1"}}
      )

      assert_equal "Codex", recording.last_event[:client_name]
      assert_equal "3.1", recording.last_event[:client_version]
    end
  end

  # Stateless keeps nothing between requests, so a clientInfo from `initialize` must not
  # turn up on a later `tools/call` that doesn't carry its own. Guessing the link from
  # IP or headers would hand one client's name to another behind the same proxy. The
  # User-Agent still gets through, so the backend has something to go on.
  def test_stateless_does_not_carry_client_identity_from_initialize_to_a_later_call
    run_e2e_server(initialize: false, stateless: true) do |client, recording|
      client.initialize!(name: "claude-code", version: "2.1.114")
      client.call_tool("echo", {msg: "hi", session_id: "start"})

      event = recording.last_event
      refute_nil event
      assert_nil event[:client_name]
      assert_nil event[:client_version]
      refute_nil event[:parameters].dig("extra", "requestInfo", "headers", "user-agent")
    end
  end

  # Two clients on one sessionful server, calls interleaved: every event gets the name
  # of the client that made that call, never the other one's.
  def test_each_session_keeps_its_own_client_identity_over_real_http
    run_e2e_server(initialize: false) do |cursor, recording|
      claude = cursor.another_client
      cursor.initialize!(name: "cursor-vscode", version: "2.6.22")
      claude.initialize!(name: "claude-code", version: "2.1.114")

      cursor.call_tool("echo", {msg: "cursor-1", session_id: "start"})
      claude.call_tool("echo", {msg: "claude-1", session_id: "start"})
      cursor.call_tool("echo", {msg: "cursor-2", session_id: "start"})
      claude.call_tool("echo", {msg: "claude-2", session_id: "start"})
      AgentCat.flush(timeout: 2)

      names = recording.events.to_h { |event| [event[:parameters]["arguments"]["msg"], event[:client_name]] }
      assert_equal(
        {"cursor-1" => "cursor-vscode", "claude-1" => "claude-code", "cursor-2" => "cursor-vscode", "claude-2" => "claude-code"},
        names
      )
    end
  end

  def test_protocol_version_tag_is_captured_from_the_modern_envelope_over_real_http
    run_e2e_server(initialize: false, stateless: true) do |client, recording|
      client.call_tool_with_meta(
        "echo", {msg: "hi", session_id: "start"},
        {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => {},
          "io.modelcontextprotocol/clientInfo" => {"name" => "Claude Code", "version" => "1.0"}
        },
        protocol_version: "2026-07-28"
      )

      assert_equal "2026-07-28", recording.last_event[:tags]["agentcat_protocol_version"]
    end
  end

  # Stateless HTTP is the case the client called out by name. Its dispatch is eager (the
  # gem answers inline, no SSE body), so this path is what the transport hook's own capture
  # covers; the sessionful test below covers the deferred body. Headers must land either way.
  def test_incoming_http_headers_are_captured_on_a_stateless_request_over_real_http
    run_e2e_server(initialize: false, stateless: true) do |client, recording|
      client.call_tool("echo", {msg: "hi", session_id: "start"})

      headers = recording.last_event[:parameters].dig("extra", "requestInfo", "headers")

      assert_kind_of Hash, headers
      assert_equal "application/json", headers["content-type"]
      refute_nil headers["user-agent"]
    end
  end

  # The in-process shortcut's own test for this used a flattened, non-spec content block
  # ({type: "resource", blob: ...}) - only a real `MCP::Tool::Response` going through the
  # genuine dispatch path produces the actual wire shape ({type: "resource", resource:
  # {blob: ...}}), which is exactly the shape that was silently not being redacted before.
  # Sanitization only touches the *published* event, never the response the real caller
  # gets back - the agent still sees its own resource content untouched.
  def test_binary_resource_content_is_redacted_in_the_published_event_over_real_http
    blob_tool = echo_tool(name: "blob", input_schema: {type: "object", properties: {}}) do |**|
      MCP::Tool::Response.new([{type: "resource", resource: {uri: "file:///x.bin", blob: "abc", mimeType: "application/octet-stream"}}])
    end

    run_e2e_server(tools: [blob_tool]) do |client, recording|
      response = client.call_tool("blob", {session_id: "start"})

      assert_equal "abc", response[:result][:content].last.dig(:resource, :blob)
      assert_equal AgentCat::Sanitization::BINARY_RESOURCE_REDACTED, recording.last_event[:response][:content].last[:text]
    end
  end

  def test_event_tags_reach_the_first_class_tags_field_over_real_http
    run_e2e_server(event_tags: ->(*) { {"env" => "prod"} }) do |client, recording|
      client.call_tool("echo", {msg: "hi", session_id: "start"})

      assert_equal "prod", recording.last_event[:tags]["env"]
      assert recording.last_event[:tags].key?("agentcat_session_id_source")
    end
  end

  def test_supplied_session_mirrors_as_active_over_real_http
    output_tool = echo_tool(output_schema: {type: "object", properties: {}}) do |msg:, **|
      MCP::Tool::Response.new([{type: "text", text: msg}], structured_content: {})
    end

    run_e2e_server(tools: [output_tool]) do |client, _recording|
      first = client.call_tool("echo", {msg: "one", session_id: "start"})
      session_id = first[:result][:structuredContent][:mcp_session][:session_id]

      second = client.call_tool("echo", {msg: "two", session_id: session_id})
      texts = second[:result][:content].map { |block| block[:text] }

      assert_equal ["two"], texts
      assert_equal "active", second[:result][:structuredContent][:mcp_session][:status]
      assert_equal session_id, second[:result][:structuredContent][:mcp_session][:session_id]
    end
  end

  # Exercises the real `mcp` gem's own JSON Schema validator against a genuine `oneOf`
  # body - the in-process shortcut's equivalent test never proved the real dispatch path
  # actually accepts a composed-schema call once AgentCat has left the schema alone.
  def test_composed_input_schema_is_untouched_and_still_callable_over_real_http
    composed_tool = MCP::Tool.define(
      name: "composed",
      input_schema: {
        oneOf: [
          {type: "object", properties: {a: {type: "string"}}, required: ["a"]},
          {type: "object", properties: {b: {type: "string"}}, required: ["b"]}
        ]
      }
    ) { |server_context: nil, **arguments| MCP::Tool::Response.new([{type: "text", text: arguments.keys.join(",")}]) }

    run_e2e_server(tools: [composed_tool]) do |client, recording|
      listed = client.list_tools[:result][:tools].find { |tool| tool[:name] == "composed" }
      refute listed[:inputSchema].key?(:properties)

      response = client.call_tool("composed", {a: "value"})
      texts = response[:result][:content].map { |block| block[:text] }

      assert_equal ["a"], texts
      assert_equal "foreign", recording.last_event[:tags]["agentcat_session_id_source"]
    end
  end

  def test_get_more_tools_is_marked_read_only_over_real_http
    run_e2e_server do |client, _recording|
      listed = client.list_tools[:result][:tools].find { |tool| tool[:name] == "get_more_tools" }

      assert_equal true, listed.dig(:annotations, :readOnlyHint)
    end
  end

  # The reference SDKs attach the incoming HTTP headers to the event at
  # `parameters.extra.requestInfo.headers`, so AgentCat can identify a client from its
  # headers (e.g. User-Agent) even when `_meta` carries no clientInfo. The `mcp` gem
  # never hands the request to `Server#handle`, so this only exists because our
  # transport hook captured it from the real Rack env.
  def test_incoming_http_headers_are_captured_on_the_event_over_real_http
    run_e2e_server do |client, recording|
      client.call_tool("echo", {msg: "hi", session_id: "start"})

      parameters = recording.last_event[:parameters]
      headers = parameters.dig("extra", "requestInfo", "headers")

      assert_kind_of Hash, headers
      assert_equal "application/json", headers["content-type"]
      assert_includes headers["accept"], "application/json"
      # Net::HTTP always sends a User-Agent; that's exactly the header AgentCat reads
      # to tell clients apart.
      refute_nil headers["user-agent"]
      assert_match(%r{\Ahttp://[^/]+/}, parameters.dig("extra", "requestInfo", "url"))
      assert headers.values.all?(String), "every header value is one string"
      refute_nil parameters.dig("extra", "requestId")
      # The raw, unstripped arguments still ride alongside the SDK's `extra`.
      assert_equal "hi", parameters.dig("arguments", "msg")
    end
  end

  # The hooks run on a thread of their own, where the request's fiber-local
  # headers are out of reach. The ToolCall carries them from the request thread.
  def test_identify_sees_the_http_headers_over_real_http
    seen = Queue.new
    identify = ->(tool_call) {
      seen << tool_call
      AgentCat::UserIdentity.new(user_id: tool_call.headers.fetch("x-user-id"))
    }

    run_e2e_server(identify: identify) do |client, recording|
      client.call_tool("echo", {msg: "hi", session_id: "start"}, headers: {"X-User-Id" => "user-42"})
      AgentCat.flush(timeout: 2)

      tool_call = seen.pop
      assert_equal "user-42", tool_call.headers["x-user-id"]
      assert_equal "e2e-client", tool_call.client_name
      assert_equal "0.1.0", tool_call.client_version
      refute_nil tool_call.transport_session_id
      assert_equal tool_call.transport_session_id, tool_call.headers["mcp-session-id"]
      assert_kind_of Hash, tool_call.request
      assert_equal "user-42", recording.last_event[:actor_id]
    end
  end

  def test_hooks_get_client_identity_from_sep_2575_meta_over_real_http
    seen = Queue.new
    tags = ->(tool_call) {
      seen << tool_call
      {}
    }

    run_e2e_server(initialize: false, stateless: true, event_tags: tags) do |client, _recording|
      client.call_tool_with_meta(
        "echo", {msg: "hi", session_id: "start"},
        {
          "io.modelcontextprotocol/protocolVersion" => "2026-07-28",
          "io.modelcontextprotocol/clientCapabilities" => {},
          "io.modelcontextprotocol/clientInfo" => {"name" => "Claude Code", "version" => "1.0"}
        },
        protocol_version: "2026-07-28"
      )
      AgentCat.flush(timeout: 2)

      tool_call = seen.pop
      assert_equal "Claude Code", tool_call.client_name
      assert_equal "1.0", tool_call.client_version
      assert_equal "2026-07-28", tool_call.protocol_version
      assert_nil tool_call.transport_session_id
      refute_empty tool_call.headers
    end
  end

  # Same keys the TS SDK puts in `extra`: the request's `_meta` as sent, plus the
  # session id on a sessionful transport.
  def test_request_meta_and_session_id_land_in_extra_over_real_http
    run_e2e_server do |client, recording|
      client.call_tool_with_meta("echo", {msg: "hi", session_id: "start"}, {"progressToken" => 3, "claudecode/toolUseId" => "toolu_abc"})

      extra = recording.last_event[:parameters]["extra"]

      assert_equal({"progressToken" => 3, "claudecode/toolUseId" => "toolu_abc"}, extra["_meta"])
      assert_equal extra.dig("requestInfo", "headers", "mcp-session-id"), extra["sessionId"]
      refute_nil extra["sessionId"]
    end
  end

  # Stateless issues no session, so there's no `sessionId` to report — `_meta` still lands.
  def test_stateless_request_has_meta_but_no_session_id_over_real_http
    run_e2e_server(initialize: false, stateless: true) do |client, recording|
      client.call_tool_with_meta("echo", {msg: "hi", session_id: "start"}, {"claudecode/toolUseId" => "toolu_abc"})

      extra = recording.last_event[:parameters]["extra"]

      assert_equal({"claudecode/toolUseId" => "toolu_abc"}, extra["_meta"])
      refute extra.key?("sessionId")
    end
  end

  # The `mcp` gem answers an unknown tool with a JSON-RPC error before any tool
  # runs. The client gets that error as is, and AgentCat records one error event.
  def test_unknown_tool_is_recorded_and_the_error_reaches_the_client_over_real_http
    run_e2e_server do |client, recording|
      response = client.call_tool("no_such_tool", {msg: "hi"})
      AgentCat.flush(timeout: 2)

      refute response.key?(:result)
      assert_equal(-32602, response.dig(:error, :code))
      assert_match(/Tool not found: no_such_tool/, response[:error].to_s)
      assert_equal 1, recording.events.size
      event = recording.last_event
      assert_equal "no_such_tool", event[:resource_name]
      assert event[:is_error]
      assert_equal "Tool not found: no_such_tool", event[:error]["message"]
      assert_equal "e2e-client", event[:client_name]
    end
  end

  # A missing required argument is the gem's isError result. With a session the agent
  # already holds, the client gets the gem's result unchanged.
  def test_missing_required_argument_is_recorded_and_the_result_is_unchanged_over_real_http
    run_e2e_server do |client, recording|
      first = client.call_tool("echo", {msg: "hi"})
      session_id = first.dig(:result, :_meta, :agentcat, :session_id)

      response = client.call_tool("echo", {session_id: session_id})
      AgentCat.flush(timeout: 2)

      assert_equal({content: [{type: "text", text: "Missing required arguments: msg"}], isError: true}, response[:result])
      assert_equal 2, recording.events.size
      event = recording.last_event
      assert_equal "echo", event[:resource_name]
      assert event[:is_error]
      assert_equal "Missing required arguments: msg", event[:error]["message"]
      assert_equal session_id, event[:session_id]
    end
  end
end
