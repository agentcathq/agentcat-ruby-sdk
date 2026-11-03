require_relative "test_helper"
require "json"
require "socket"
require "timeout"

# Publishes real HTTP requests to an in-process mock of the AgentCat API.
class ClientTest < Minitest::Test
  include AgentCatTestHelpers

  Request = Struct.new(:method, :path, :headers, :body, :raw)

  def setup
    super
    @requests = Queue.new
    @listener = TCPServer.new("127.0.0.1", 0)
    @thread = Thread.new { serve }
    ENV["AGENTCAT_API_URL"] = "http://127.0.0.1:#{@listener.addr[1]}"
  end

  def teardown
    ENV.delete("AGENTCAT_API_URL")
    ENV.delete("AGENTCAT_API_KEY")
    AgentCat::Client.reset_base_url!
    @thread.kill
    @listener.close
  end

  def test_publishes_tool_call_events_to_the_events_endpoint
    ENV["AGENTCAT_API_KEY"] = "test-key"
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    result = tool_result(server, "echo", {msg: "hello", context: "because"})
    request = next_request

    assert_equal "POST", request.method
    assert_equal "/v1/public/events/", request.path
    assert_equal "Bearer test-key", request.headers["authorization"]
    assert_equal "application/json", request.headers["content-type"]

    event = request.body
    assert_equal PROJECT_ID, event["project_id"]
    assert_equal "mcp:tools/call", event["event_type"]
    assert_equal "echo", event["resource_name"]
    assert_equal agentcat_meta(result)[:session_id], event["session_id"]
    assert_equal(
      {"name" => "echo", "arguments" => {"session_id" => "start", "msg" => "hello", "context" => "because"}, "extra" => {"requestId" => 2}},
      event["parameters"]
    )
    assert_equal "because", event["user_intent"]
    # Only goes over the wire because agentcat-api >= 0.0.3 models these fields.
    assert_kind_of Integer, event["input_tokens"]
    assert_equal 2, event["output_tokens"]
    # The event keeps the tool's own result; the session_id text block is wire-only.
    assert_equal [{"type" => "text", "text" => "hello"}], event.dig("response", "content")
    assert_equal false, event["is_error"]
    assert_kind_of Integer, event["duration"]
    assert_match(/\A\d{4}-\d{2}-\d{2}T/, event["timestamp"])
    assert_equal "test-server", event["server_name"]
    assert_equal "1.2.3", event["server_version"]
    assert_equal "Ruby", event["sdk_language"]
    assert_equal AgentCat::VERSION, event["agentcat_version"]
    assert_equal true, event.dig("properties", "agentcat_context_supplied")
    assert_equal false, event.dig("properties", "agentcat_via_get_more_tools")
  end

  def test_context_supplied_is_false_when_the_agent_omits_it
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal false, next_request.body.dig("properties", "agentcat_context_supplied")
  end

  def test_via_get_more_tools_is_true_for_that_tool
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    tool_result(server, "get_more_tools", {context: "looking for a delete endpoint"})

    assert_equal true, next_request.body.dig("properties", "agentcat_via_get_more_tools")
  end

  def test_omits_authorization_without_an_api_key
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    tool_result(server, "echo", {msg: "hello"})

    refute next_request.headers.key?("authorization")
  end

  def test_base_url_path_prefix_is_respected
    ENV["AGENTCAT_API_URL"] = "http://127.0.0.1:#{@listener.addr[1]}/prefix/"
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "/prefix/v1/public/events/", next_request.path
  end

  def test_api_base_url_option_overrides_the_env_var
    ENV["AGENTCAT_API_URL"] = "http://127.0.0.1:1" # unreachable - should never actually be hit
    server = build_server
    AgentCat.track(server, PROJECT_ID, AgentCat::Options.new(api_base_url: "http://127.0.0.1:#{@listener.addr[1]}"))

    tool_result(server, "echo", {msg: "hello"})

    assert_equal "/v1/public/events/", next_request.path
  end

  def test_api_base_url_option_is_ignored_with_a_custom_client
    client = RecordingClient.new
    server = build_server
    AgentCat.track(server, PROJECT_ID, AgentCat::Options.new(client: client, api_base_url: "http://127.0.0.1:1"))

    tool_result(server, "echo", {msg: "hello"})

    assert_equal 1, client.events.size
    assert @requests.empty?, "the real HTTP client should never have been configured or hit"
  end

  # Tripwire for the `AgentCatApi::PublishEventRequest` reopening in client.rb: the
  # generated model's enum predates `agentcat:custom` and would otherwise reject it
  # with a plain ArgumentError from the generated setter. A future `agentcat-api`
  # bump, regenerated from the same stale spec, would silently reintroduce that
  # rejection if the reopening weren't there to catch it - this test is the catch.
  def test_custom_event_type_survives_the_generated_clients_stale_enum
    request = AgentCatApi::PublishEventRequest.new(
      id: "evt_x", project_id: PROJECT_ID, event_type: AgentCat::Client::CUSTOM_EVENT_TYPE, timestamp: Time.now.utc.iso8601
    )

    assert_equal "agentcat:custom", request.event_type
  end

  # Tripwire for the `_to_hash` patch in client.rb: the generated model calls
  # `value.compact` on every array, so `[1, nil, 2]` went out as `[1, 2]`. Goes
  # through the real generated client and the real HTTP body.
  def test_arrays_keep_nil_elements_on_the_wire
    AgentCat::Client.post_event(
      project_id: PROJECT_ID, id: "evt_x", event_type: "mcp:tools/call", timestamp: Time.now.utc.iso8601,
      parameters: {"arguments" => {"list" => [1, nil, 2], "nested" => [[nil, "a"], {"k" => [nil]}]}},
      response: {"content" => [nil, {"type" => "text", "text" => "x"}]},
      properties: {"slots" => [nil]}
    )

    request = next_request
    assert_includes request.raw, '"list":[1,null,2]'
    assert_equal [[nil, "a"], {"k" => [nil]}], request.body.dig("parameters", "arguments", "nested")
    assert_equal [nil, {"type" => "text", "text" => "x"}], request.body.dig("response", "content")
    assert_equal [nil], request.body.dig("properties", "slots")
  end

  # TS sends `sessionId: null` when there is no session; the generated model only
  # writes a nullable key it was given, so the SDK must hand it over as nil.
  def test_a_missing_session_id_is_sent_as_an_explicit_null
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    AgentCat.publish_custom_event(server, PROJECT_ID, resource_name: "no-session")
    request = next_request

    assert_includes request.raw, '"session_id":null'
  end

  def test_every_generated_model_keeps_nil_array_elements
    models = AgentCatApi.constants.map { |name| AgentCatApi.const_get(name) }
      .select { |klass| klass.is_a?(Class) && klass.method_defined?(:_to_hash) }

    refute_empty models
    models.each do |klass|
      assert_equal [1, nil, 2], klass.allocate._to_hash([1, nil, 2]), "#{klass} still compacts arrays"
    end
  end

  def test_the_generated_clients_enum_still_rejects_a_genuinely_bogus_event_type
    assert_raises(ArgumentError) do
      AgentCatApi::PublishEventRequest.new(
        id: "evt_x", project_id: PROJECT_ID, event_type: "not-a-real-event-type", timestamp: Time.now.utc.iso8601
      )
    end
  end

  def test_nil_project_id_publishes_nothing
    server = build_server
    AgentCat.track(server)

    tool_result(server, "echo", {msg: "hello"})

    assert @requests.empty?
  end

  def test_tool_errors_are_reported_and_re_raised
    tool = echo_tool { |**| raise "tool exploded" }
    server = build_server(tools: [tool])
    AgentCat.track(server, PROJECT_ID)

    response = call_tool(server, "echo", {msg: "hello"})

    refute_nil response[:error]
    event = next_request.body
    assert_equal true, event["is_error"]
    assert_equal "RuntimeError", event.dig("error", "type")
    assert_equal "tool exploded", event.dig("error", "message")
    assert_equal "ruby", event.dig("error", "platform")
    assert_kind_of String, event.dig("error", "stack")
    assert_kind_of Array, event.dig("error", "frames")
    refute event.key?("response")
  end

  def test_unreachable_api_does_not_break_tool_calls
    socket = TCPServer.new("127.0.0.1", 0)
    closed_port = socket.addr[1]
    socket.close
    ENV["AGENTCAT_API_URL"] = "http://127.0.0.1:#{closed_port}"
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    assert_equal "hello", texts_of(tool_result(server, "echo", {msg: "hello"})).last
  end

  def test_configuration_uses_the_default_base_url
    ENV.delete("AGENTCAT_API_URL")
    config = AgentCat::Client.configuration

    assert_equal "https", config.scheme
    assert_equal "api.agentcat.com", config.host
    assert_equal "", config.base_path
    assert_equal AgentCat::Client.read_timeout_seconds, config.timeout
  end

  def test_configuration_parses_custom_base_urls
    ENV["AGENTCAT_API_URL"] = "http://localhost:8080/api/"
    config = AgentCat::Client.configuration

    assert_equal "http", config.scheme
    assert_equal "localhost:8080", config.host
    assert_equal "/api", config.base_path
  end

  def test_post_event_swallows_client_errors
    ENV["AGENTCAT_API_URL"] = "not a url"

    assert_nil AgentCat::Client.post_event({project_id: PROJECT_ID, event_type: "mcp:tools/call"})
  end

  private

  def next_request
    Timeout.timeout(5) { @requests.pop }
  end

  def serve
    loop do
      client = @listener.accept
      method, path, = client.gets.split(" ")
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip.downcase] = value.strip
      end
      body = client.read(headers["content-length"].to_i)
      @requests << Request.new(method, path, headers, body.empty? ? nil : JSON.parse(body), body)
      payload = {status: "accepted"}.to_json
      client.write("HTTP/1.1 200 OK\r\nContent-Type: application/json\r\nContent-Length: #{payload.bytesize}\r\nConnection: close\r\n\r\n#{payload}")
      client.close
    end
  rescue IOError, Errno::EBADF
    nil
  end
end
