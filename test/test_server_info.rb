require_relative "test_helper"
require "minitest/mock"
require "socket"

class ServerInfoTest < Minitest::Test
  include AgentCatTestHelpers

  LONG_DESCRIPTION = ("A long description. " * 100).freeze

  # Evaluates the sigs of the methods the tests stub; sorbet-runtime warns when a stub
  # replaces a method whose sig never ran.
  %i[now list_timeout build_timeout].each { |name| AgentCat::ServerInfo.public_send(name) }

  def demo_tools
    alpha = MCP::Tool.define(name: "alpha", description: "First tool") { |server_context: nil| MCP::Tool::Response.new([{type: "text", text: "alpha"}]) }
    beta = MCP::Tool.define(
      name: "beta",
      title: "Beta Tool",
      description: LONG_DESCRIPTION,
      input_schema: {type: "object", properties: {query: {type: "string", description: "What to look up"}}, required: ["query"]},
      output_schema: {type: "object", properties: {answer: {type: "string"}}},
      annotations: {read_only_hint: true}
    ) { |query:, server_context: nil| MCP::Tool::Response.new([{type: "text", text: query}], structured_content: {answer: query}) }
    gamma = MCP::Tool.define(name: "gamma", description: "Third tool") { |server_context: nil| MCP::Tool::Response.new([{type: "text", text: "gamma"}]) }
    [alpha, beta, gamma]
  end

  def demo_server(tools: demo_tools, **overrides)
    prompt = MCP::Prompt.define(name: "summary", description: "Summarize a topic", arguments: [MCP::Prompt::Argument.new(name: "topic", required: true)]) do |_args, server_context: nil|
      MCP::Prompt::Result.new(messages: [])
    end
    plain_prompt = MCP::Prompt.define(name: "hello", description: "Say hello") { |_args, server_context: nil| MCP::Prompt::Result.new(messages: []) }
    MCP::Server.new(
      name: "demo-server",
      version: "1.2.3",
      title: "Demo Title",
      instructions: "Use the demo tools.",
      tools: tools,
      prompts: [prompt, plain_prompt],
      resources: [
        MCP::Resource.new(uri: "file:///readme.txt", name: "readme", description: "The readme"),
        MCP::Resource.new(uri: "file:///notes.txt", name: "notes", description: "The notes")
      ],
      resource_templates: [MCP::ResourceTemplate.new(uri_template: "file:///docs/{name}", name: "doc", description: "A document")],
      **overrides
    )
  end

  def track_demo(server = demo_server, project_id: PROJECT_ID, **options)
    track(server, project_id: project_id, **options)
  end

  # Straight through `handle`: no `tools/list` first, so a test sees only the requests it makes.
  def call_alpha(server, name: "alpha", arguments: {})
    response = server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: name, arguments: arguments}})
    refute_nil response[:result], response.inspect
    response[:result]
  end

  def request_tools_list(server)
    server.handle({jsonrpc: "2.0", id: 1, method: "tools/list", params: {}})
  end

  def replace_handler(server, method, handler)
    server.instance_variable_get(:@handlers)[method] = handler
  end

  def wire(value)
    JSON.parse(JSON.generate(value))
  end

  def test_v16_the_global_test_setup_replaces_the_sender_so_no_heartbeat_reaches_the_network
    assert_instance_of ServerInfoRecorder, AgentCat::ServerInfo.sender

    server = demo_server
    AgentCat.track(server, PROJECT_ID, AgentCat::Options.new)
    assert_equal AgentCat::Client, AgentCat.tracker_for(server).options.client

    request_tools_list(server)

    assert_equal 1, server_info_bodies.size
  end

  def test_v1_one_tool_call_sends_the_whole_server_info
    server = demo_server
    track_demo(server)
    age_server_info_memory

    call_alpha(server)
    bodies = server_info_bodies

    assert_equal 1, bodies.size
    body = bodies.first
    assert_equal %w[features instructions project_id server_name server_title server_version], body.keys.sort
    assert_equal PROJECT_ID, body["project_id"]
    assert_equal "demo-server", body["server_name"]
    assert_equal "1.2.3", body["server_version"]
    assert_equal "Demo Title", body["server_title"]
    assert_equal "Use the demo tools.", body["instructions"]

    features = body["features"]
    assert_equal wire(list_tools(server)), features["tools"]
    assert_equal %w[alpha beta gamma get_more_tools], features["tools"].map { |tool| tool["name"] }
    assert_includes features["tools"].first["inputSchema"]["properties"].keys, "context"
    beta = features["tools"].find { |tool| tool["name"] == "beta" }
    assert_equal LONG_DESCRIPTION, beta["description"]
    assert_equal 2000, beta["description"].size
    assert_equal "Beta Tool", beta["title"]
    assert beta.key?("outputSchema")
    assert beta.key?("annotations")
    assert_equal 2, features["resources"].size
    assert_equal 1, features["resourceTemplates"].size
    assert_equal 2, features["prompts"].size
    assert_equal [{"name" => "topic", "required" => true}], features["prompts"].first["arguments"]
  end

  def test_v2_every_page_of_the_tool_list_is_read
    tools = (1..5).map { |n| echo_tool(name: "tool#{n}") }
    server = demo_server(tools: tools, page_size: 2)
    track_demo(server)

    request_tools_list(server)
    tools = server_info_bodies.first["features"]["tools"]

    assert_equal %w[tool1 tool2 tool3 tool4 tool5 get_more_tools], tools.map { |tool| tool["name"] }
    assert_equal 1, tools.count { |tool| tool["name"] == "get_more_tools" }
  end

  def test_v3_a_server_with_tools_only_sends_the_tool_list_only
    server = demo_server(capabilities: {tools: {listChanged: true}})
    track_demo(server)

    request_tools_list(server)

    assert_equal ["tools"], server_info_bodies.first["features"].keys
  end

  def test_v4_a_failed_prompt_list_is_left_out
    server = demo_server
    track_demo(server)
    replace_handler(server, "prompts/list", ->(_params) { raise "prompts are down" })

    request_tools_list(server)
    bodies = server_info_bodies

    assert_equal 1, bodies.size
    refute bodies.first["features"].key?("prompts")
    assert_equal %w[alpha beta gamma get_more_tools], bodies.first["features"]["tools"].map { |tool| tool["name"] }
  end

  def test_v5_a_failed_tool_list_sends_nothing
    server = demo_server
    track_demo(server)
    age_server_info_memory
    replace_handler(server, "tools/list", ->(_params) { raise "tools are down" })

    call_alpha(server)

    assert_equal 0, server_info_bodies.size
  end

  def test_v6_a_list_that_repeats_its_cursor_fails_quickly
    server = demo_server
    track_demo(server)
    replace_handler(server, "prompts/list", ->(_params) { {prompts: [{name: "again"}], nextCursor: "1"} })
    started = AgentCat::Clock.monotonic_now

    request_tools_list(server)
    bodies = server_info_bodies

    assert_operator AgentCat::Clock.monotonic_now - started, :<, 5
    assert_equal 1, bodies.size
    refute bodies.first["features"].key?("prompts")
  end

  def test_v6_a_list_fails_after_100_pages
    calls = 0
    handler = ->(_params, _context) {
      calls += 1
      {prompts: [], nextCursor: calls.to_s}
    }

    assert_raises(AgentCat::ServerInfo::ListFailed) { AgentCat::ServerInfo.read_pages(handler, "prompts", nil) }
    assert_equal 100, calls
  end

  def test_v15_the_heartbeat_names_the_server_as_its_events_do
    server = demo_server
    client = track_demo(server)
    age_server_info_memory

    call_alpha(server)
    AgentCat.flush(timeout: 1)
    body = server_info_bodies.first

    assert_equal client.last_event[:server_name], body["server_name"]
    assert_equal client.last_event[:server_version], body["server_version"]
  end

  def test_v11_the_redaction_function_runs_on_the_text_but_not_on_the_names
    tool = MCP::Tool.define(
      name: "secret_tool",
      description: "secret tool",
      input_schema: {type: "object", properties: {plan: {type: "string", description: "a secret"}}}
    ) { |server_context: nil, **| MCP::Tool::Response.new([]) }
    server = MCP::Server.new(
      name: "secret-server",
      version: "1.0.0",
      instructions: "the secret plan",
      tools: [tool],
      resources: [MCP::Resource.new(uri: "file:///secret.txt", name: "secret_file", description: "a secret file")]
    )
    track(server, project_id: PROJECT_ID, redact_sensitive_information: ->(text) { text.gsub("secret", "[x]") })

    request_tools_list(server)
    body = server_info_bodies.first

    assert_equal "secret-server", body["server_name"]
    assert_equal "the [x] plan", body["instructions"]
    listed = body["features"]["tools"].find { |item| item["name"] == "secret_tool" }
    refute_nil listed
    assert_equal "[x] tool", listed["description"]
    assert_equal "a [x]", listed["inputSchema"]["properties"]["plan"]["description"]
    resource = body["features"]["resources"].first
    assert_equal "file:///secret.txt", resource["uri"]
    assert_equal "secret_file", resource["name"]
    assert_equal "a [x] file", resource["description"]
  end

  def test_v12_a_failing_redaction_function_sends_nothing
    server = demo_server
    track_demo(server, redact_sensitive_information: ->(_text) { raise "redaction is down" })

    request_tools_list(server)

    assert_equal 0, server_info_bodies.size
  end

  def test_v12_a_redaction_function_that_returns_no_string_sends_nothing
    server = demo_server
    track_demo(server, redact_sensitive_information: ->(_text) {})

    request_tools_list(server)

    assert_equal 0, server_info_bodies.size
  end

  def test_v12_redaction_stops_at_the_build_deadline
    options = AgentCat::Options.new(redact_sensitive_information: ->(text) { text })
    fields = {server_title: "", instructions: "", features: {"tools" => []}}

    assert_nil AgentCat::Redaction.apply_server_info_redaction(fields, options, deadline: AgentCat::Clock.monotonic_now - 1)
    assert_equal fields, AgentCat::Redaction.apply_server_info_redaction(fields, options, deadline: AgentCat::Clock.monotonic_now + 30)
  end

  def test_v7_one_heartbeat_an_hour
    server = demo_server
    track_demo(server)
    clock = [1000.0]

    AgentCat::ServerInfo.stub(:now, -> { clock[0] }) do
      age_server_info_memory
      3.times { call_alpha(server) }
      assert_equal 1, server_info_bodies.size

      clock[0] += 3599
      call_alpha(server)
      assert_equal 1, server_info_bodies.size

      clock[0] += 1
      call_alpha(server)
      assert_equal 2, server_info_bodies.size
    end
  end

  def test_v8_two_servers_with_one_name_share_the_hour
    first = demo_server
    second = demo_server
    track_demo(first)
    track_demo(second)

    request_tools_list(first)
    request_tools_list(second)

    assert_equal 1, server_info_bodies.size
  end

  def test_v8_two_servers_with_two_names_send_one_each
    first = demo_server
    second = demo_server(name: "other-server")
    track_demo(first)
    track_demo(second)

    request_tools_list(first)
    request_tools_list(second)

    assert_equal %w[demo-server other-server], server_info_bodies.map { |body| body["server_name"] }.sort
  end

  def test_v9_no_heartbeat_without_a_project_id
    ["", nil].each do |project_id|
      server = demo_server
      track_demo(server, project_id: project_id)

      request_tools_list(server)
    end

    assert_equal 0, server_info_bodies.size
  end

  def test_v9_no_heartbeat_with_tracing_off
    server = demo_server
    track_demo(server, enable_tracing: false)
    age_server_info_memory

    request_tools_list(server)
    call_alpha(server)

    assert_equal 0, server_info_bodies.size
  end

  def test_no_heartbeat_while_a_fake_records
    AgentCat.fake
    server = demo_server
    AgentCat.track(server, PROJECT_ID)

    request_tools_list(server)

    assert_equal 0, server_info_bodies.size
  end

  # Every failure stays inside the SDK. Each case runs with a logger on standard error
  # and with `Thread.abort_on_exception`, so an error that leaves a thread fails the
  # test, and so does any output.
  def assert_quiet_and_unharmed(server, request: :tool_call)
    previous_abort = Thread.abort_on_exception
    previous_logger = AgentCat.logger
    Thread.abort_on_exception = true
    assert_output("", "") do
      AgentCat.logger = Logger.new($stderr, level: Logger::WARN)
      started = AgentCat::Clock.monotonic_now
      if request == :tool_call
        assert_equal "alpha", call_alpha(server)[:content].last[:text]
      else
        assert_equal %w[alpha beta gamma get_more_tools], request_tools_list(server)[:result][:tools].map { |tool| tool[:name] }
      end
      assert_operator AgentCat::Clock.monotonic_now - started, :<, 0.5
      yield if block_given?
    end
  ensure
    Thread.abort_on_exception = previous_abort
    AgentCat.logger = previous_logger
  end

  def test_v10_an_api_that_never_answers_does_not_hold_the_call
    gate = Queue.new
    sender = Object.new
    sender.define_singleton_method(:post_server_info) { |_body| gate.pop }
    with_server_info_sender(sender) do
      server = demo_server
      track_demo(server)
      age_server_info_memory

      assert_quiet_and_unharmed(server)
    ensure
      gate.close
    end
  end

  def test_v10_a_failing_list_handler_does_not_reach_the_call
    server = demo_server
    track_demo(server)
    age_server_info_memory
    replace_handler(server, "resources/list", ->(_params) { raise Class.new(Exception), "not even a StandardError" }) # standard:disable Lint/InheritException

    assert_quiet_and_unharmed(server) { wait_for_server_info }
    refute server_info_bodies.first["features"].key?("resources")
  end

  def test_v10_a_list_handler_that_never_returns_costs_its_list_only
    server = demo_server
    track_demo(server)
    age_server_info_memory
    replace_handler(server, "prompts/list", ->(_params) { sleep })

    AgentCat::ServerInfo.stub(:list_timeout, 0.2) do
      assert_quiet_and_unharmed(server) { wait_for_server_info }
    end

    assert_equal 1, server_info_bodies.size
    refute server_info_bodies.first["features"].key?("prompts")
  end

  # The function fails on the instructions only, so the call's own event (whose drop
  # logs a warning of its own) is not part of this case.
  def test_v10_a_failing_redaction_function_does_not_reach_the_call
    server = demo_server
    track_demo(server, redact_sensitive_information: ->(text) { (text == "Use the demo tools.") ? raise("redaction is down") : text })
    age_server_info_memory

    assert_quiet_and_unharmed(server) { wait_for_server_info }
    assert_equal 0, server_info_bodies.size
  end

  def test_v10_an_api_error_is_not_sent_again
    with_server_info_sender(ServerInfoRecorder.new([500])) do
      server = demo_server
      track_demo(server)
      age_server_info_memory

      assert_quiet_and_unharmed(server) { wait_for_server_info }
      call_alpha(server)
      request_tools_list(server)

      assert_equal 1, server_info_bodies.size
    end
  end

  def test_v10_a_sender_that_raises_does_not_reach_the_request
    sender = Object.new
    sender.define_singleton_method(:post_server_info) { |_body| raise "network is down" }
    with_server_info_sender(sender) do
      server = demo_server
      track_demo(server)

      assert_quiet_and_unharmed(server, request: :tools_list) { wait_for_server_info }
    end
  end

  # The hook's error is not a StandardError, and its message quotes the text it was
  # given. Neither the error nor the text may leave the SDK.
  def test_v10_a_redaction_function_that_raises_a_non_standard_error_does_not_reach_the_call
    hook_error = Class.new(Exception) # standard:disable Lint/InheritException
    server = demo_server
    track_demo(server, redact_sensitive_information: ->(text) { (text == "Use the demo tools.") ? raise(hook_error, "cannot redact: #{text}") : text })
    age_server_info_memory

    log = capture_log do
      assert_quiet_and_unharmed(server) { wait_for_server_info }
    end

    assert_equal 0, server_info_bodies.size
    refute_includes log, "Use the demo tools."
    refute_includes log, "cannot redact"
  end

  def test_v17_a_new_memory_sends_for_a_tool_list_and_a_feedback_note_only
    server = demo_server
    track_demo(server)

    call_alpha(server)
    assert_equal 0, server_info_bodies.size

    request_tools_list(server)
    assert_equal 1, server_info_bodies.size

    AgentCat::ServerInfo.reset!
    call_alpha(server, name: "get_more_tools", arguments: {context: "A tool that books flights"})
    assert_equal 2, server_info_bodies.size
  end

  def test_v18_with_no_memory_between_requests_each_tool_list_sends
    server = demo_server
    track_demo(server)

    3.times do
      AgentCat::ServerInfo.reset!
      assert_equal "alpha", call_alpha(server)[:content].last[:text]
      AgentCat::ServerInfo.reset!
      assert_equal 4, request_tools_list(server)[:result][:tools].size
    end

    assert_equal 3, server_info_bodies.size
  end

  def test_v19_a_tool_call_sends_once_the_memory_is_60_seconds_old
    server = demo_server
    track_demo(server)
    clock = [500.0]

    AgentCat::ServerInfo.stub(:now, -> { clock[0] }) do
      call_alpha(server)
      assert_equal 0, server_info_bodies.size

      clock[0] += 59
      call_alpha(server)
      assert_equal 0, server_info_bodies.size

      clock[0] += 1
      call_alpha(server)
      assert_equal 1, server_info_bodies.size
    end
  end

  def test_the_guard_empties_itself_when_full
    server = demo_server
    tracker = track_demo(server) && AgentCat.tracker_for(server)
    attempts = (1..AgentCat::ServerInfo::MAX_KEYS).to_h { |n| [[PROJECT_ID, "server-#{n}"], AgentCat::ServerInfo.now] }
    AgentCat::ServerInfo.instance_variable_set(:@attempts, attempts)

    AgentCat::ServerInfo.check(tracker, :tools_list)

    assert_equal [[PROJECT_ID, "demo-server"]], AgentCat::ServerInfo.instance_variable_get(:@attempts).keys
    assert_equal 1, server_info_bodies.size
  end

  def test_v13_a_413_sends_once_more_without_the_schemas
    first, second = with_server_info_sender(ServerInfoRecorder.new([413, 202])) do
      server = demo_server
      track_demo(server)

      request_tools_list(server)
      server_info_bodies
    end

    refute_nil second
    assert first["features"]["tools"].all? { |tool| tool.key?("inputSchema") }
    second["features"]["tools"].each do |tool|
      refute tool.key?("inputSchema"), tool["name"]
      refute tool.key?("outputSchema"), tool["name"]
    end
    strip = ->(tool) { tool.slice("name", "title", "description", "annotations") }
    assert_equal first["features"]["tools"].map(&strip), second["features"]["tools"].map(&strip)
    assert_equal first.except("features"), second.except("features")
    assert_equal first["features"].except("tools"), second["features"].except("tools")
  end

  def test_v13_a_second_413_ends_the_attempt
    with_server_info_sender(ServerInfoRecorder.new([413])) do
      server = demo_server
      track_demo(server)

      request_tools_list(server)

      assert_equal 2, server_info_bodies.size
    end
  end

  # The real client against a local API.
  class LocalApi
    attr_reader :requests

    def initialize(status)
      @status = status
      @requests = Queue.new
      @listener = TCPServer.new("127.0.0.1", 0)
      @thread = Thread.new { loop { answer(@listener.accept) } }
    end

    def url
      "http://127.0.0.1:#{@listener.addr[1]}"
    end

    def close
      @thread.kill
      @listener.close
    end

    private

    def answer(socket)
      request_line = socket.gets.to_s
      headers = {}
      while (line = socket.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.to_s.strip
      end
      body = socket.read(headers["content-length"].to_i)
      @requests << {path: request_line.split(" ")[1], headers: headers, body: JSON.parse(body)}
      reply = JSON.generate(status: "accepted")
      socket.write("HTTP/1.1 #{@status} X\r\nContent-Type: application/json\r\nContent-Length: #{reply.bytesize}\r\nConnection: close\r\n\r\n#{reply}")
    ensure
      socket.close
    end
  end

  # The heartbeat uses the tracked server's client here. Every heartbeat thread ends
  # before the base URL is reset and the recorder comes back, so none can send to
  # another URL after the test.
  def with_local_api(status)
    api = LocalApi.new(status)
    with_server_info_sender(nil) { yield api }
  ensure
    wait_for_server_info(timeout: nil)
    api&.close
    AgentCat::Client.reset_base_url!
  end

  def test_v14_the_post_goes_to_the_custom_base_url
    with_local_api(202) do |api|
      server = demo_server
      AgentCat.track(server, PROJECT_ID, AgentCat::Options.new(api_base_url: "#{api.url}/custom"))

      request_tools_list(server)
      wait_for_server_info
      request = api.requests.pop(timeout: 5)

      assert_equal "/custom/v1/public/server-info/", request[:path]
      assert_equal "application/json", request[:headers]["content-type"]
      refute request[:headers].key?("authorization")
      assert_equal "demo-server", request[:body]["server_name"]
      assert_equal 4, request[:body]["features"]["tools"].size
    end
  end

  def test_the_client_returns_the_status_of_the_answer
    with_local_api(413) do |api|
      AgentCat::Client.configure_base_url(api.url)

      assert_equal 413, AgentCat::Client.post_server_info({project_id: PROJECT_ID, server_name: "s", features: {}})
      assert_equal "/v1/public/server-info/", api.requests.pop(timeout: 5)[:path]
    end
  end

  def test_the_heartbeat_carries_no_authorization_header_also_with_an_api_key
    ENV["AGENTCAT_API_KEY"] = "test-key"
    with_local_api(202) do |api|
      AgentCat::Client.configure_base_url(api.url)

      assert_equal 202, AgentCat::Client.post_server_info({project_id: PROJECT_ID, server_name: "s", features: {}})
      refute api.requests.pop(timeout: 5)[:headers].key?("authorization")
    end
  ensure
    ENV.delete("AGENTCAT_API_KEY")
  end

  def test_the_client_returns_nil_when_no_answer_comes
    listener = TCPServer.new("127.0.0.1", 0)
    port = listener.addr[1]
    listener.close
    AgentCat::Client.configure_base_url("http://127.0.0.1:#{port}")

    assert_nil AgentCat::Client.post_server_info({project_id: PROJECT_ID, server_name: "s", features: {}})
  ensure
    AgentCat::Client.reset_base_url!
  end

  def test_a_custom_client_without_server_info_support_sends_nothing
    with_server_info_sender(nil) do
      server = demo_server
      client = track_demo(server)

      request_tools_list(server)
      wait_for_server_info

      refute_respond_to client, :post_server_info
      assert_equal 0, client.events.size
    end
  end

  def record_list_starts(server, starts)
    %w[resources/list resources/templates/list prompts/list].each do |method|
      original = server.instance_variable_get(:@handlers)[method]
      replace_handler(server, method, ->(params) {
        starts << AgentCat::Clock.monotonic_now
        original.call(params)
      })
    end
  end

  def test_the_list_handlers_start_after_the_tool_call_has_returned
    finished = Queue.new
    slow = MCP::Tool.define(name: "slow", description: "A slow tool") do |server_context: nil|
      sleep 0.3
      finished << AgentCat::Clock.monotonic_now
      MCP::Tool::Response.new([{type: "text", text: "done"}])
    end
    server = demo_server(tools: [slow])
    track_demo(server)
    age_server_info_memory
    starts = Queue.new
    record_list_starts(server, starts)

    assert_equal "done", call_alpha(server, name: "slow")[:content].last[:text]
    wait_for_server_info

    assert_equal 1, server_info_bodies.size
    returned = finished.pop
    assert_equal 3, starts.size
    3.times { assert_operator starts.pop, :>=, returned }
  end

  def test_the_list_handlers_start_after_the_tool_list_request_has_been_answered
    finished = Queue.new
    server = demo_server
    track_demo(server)
    starts = Queue.new
    record_list_starts(server, starts)
    list_tools = server.instance_variable_get(:@handlers)["tools/list"]
    calls = 0
    replace_handler(server, "tools/list", ->(params) {
      calls += 1
      return list_tools.call(params) unless calls == 1

      sleep 0.3
      list_tools.call(params).tap { finished << AgentCat::Clock.monotonic_now }
    })

    request_tools_list(server)
    wait_for_server_info

    assert_equal 1, server_info_bodies.size
    returned = finished.pop
    assert_equal 3, starts.size
    3.times { assert_operator starts.pop, :>=, returned }
  end

  def test_the_check_never_raises_into_the_request
    log = capture_log { AgentCat::ServerInfo.check(Object.new, :tools_list) }

    assert_equal "DEBUG: server info check failed: NoMethodError\n", log
  end

  def test_a_malformed_request_starts_no_check_and_reaches_the_gem
    server = demo_server
    track_demo(server)

    response = JSON.parse(server.handle_json("{not json"))

    assert_equal(-32700, response.dig("error", "code"))
    assert_equal 0, server_info_bodies.size
  end
end
