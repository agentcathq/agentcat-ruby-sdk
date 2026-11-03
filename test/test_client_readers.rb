require_relative "test_helper"
require "yaml"

# Runs every way we read a client's identity against every agent name real clients
# send today, one test per name per path. We don't classify clients here, the backend
# does that, so all we check is that the name gets to the event exactly as the client
# sent it: same case, same spaces, slashes, dots, `@scope/`.
#
# The paths:
#   - the `initialize` handshake, kept on the session (stdio, sessionful HTTP)
#   - just `_meta["io.modelcontextprotocol/clientInfo"]` (stateless HTTP)
#   - the full modern `_meta` envelope
#   - the `User-Agent` header, through the real transport hook
#
# New client out there? Add it to fixtures/client_names.yml, that's all.
class ClientReadersTest < Minitest::Test
  include AgentCatTestHelpers

  FIXTURE = YAML.load_file(File.join(__dir__, "fixtures", "client_names.yml")).freeze
  CLIENT_NAMES = FIXTURE.fetch("client_names").freeze
  USER_AGENTS = FIXTURE.fetch("user_agents").freeze

  CLIENT_VERSION = "1.2.3-beta.4"
  MODERN_PROTOCOL_VERSION = "2026-07-28"

  def self.slug(value)
    value.downcase.gsub(/[^a-z0-9]+/, "_").gsub(/\A_|_\z/, "")
  end

  # One test per name per path, so a failure tells you right away which client broke
  # and where. The number keeps "Roo Code" and "Roo-Code" from getting the same
  # test name.
  CLIENT_NAMES.each_with_index do |name, i|
    suffix = format("%02d_%s", i, slug(name))

    define_method(:"test_handshake_reader_#{suffix}") do
      assert_client_identity(name, call_after_handshake(name))
    end

    define_method(:"test_stateless_meta_reader_#{suffix}") do
      meta = {"io.modelcontextprotocol/clientInfo" => {"name" => name, "version" => CLIENT_VERSION}}
      assert_client_identity(name, call_with_meta(meta))
    end

    define_method(:"test_modern_envelope_reader_#{suffix}") do
      meta = {
        "io.modelcontextprotocol/protocolVersion" => MODERN_PROTOCOL_VERSION,
        "io.modelcontextprotocol/clientCapabilities" => {},
        "io.modelcontextprotocol/clientInfo" => {"name" => name, "version" => CLIENT_VERSION}
      }
      event = call_with_meta(meta)

      assert_client_identity(name, event)
      assert_equal MODERN_PROTOCOL_VERSION, event[:tags]["agentcat_protocol_version"]
    end
  end

  USER_AGENTS.each_with_index do |user_agent, i|
    define_method(:"test_user_agent_reader_#{format("%02d_%s", i, slug(user_agent))}") do
      event = call_through_transport_hook("HTTP_USER_AGENT" => user_agent)

      assert_equal user_agent, event[:parameters]["extra"].dig("requestInfo", "headers", "user-agent")
    end
  end

  # On a gem that has `client_info`, nil from it means the client didn't identify itself.
  # The fallback for old gems must not go digging in the session and pull a name anyway.
  def test_old_gem_fallback_stays_out_when_client_info_exists
    context = Struct.new(:client_info).new(nil)
    session = Struct.new(:client).new({name: "cursor-vscode", version: CLIENT_VERSION})
    context.instance_variable_set(:@notification_target, session)

    server = build_server
    client = track(server, project_id: PROJECT_ID)
    server.tools["echo"].call(msg: "hi", session_id: AgentCat::SessionManager.mint_session_id, server_context: context)
    AgentCat.flush(timeout: 1)

    refute_nil client.last_event
    assert_nil client.last_event[:client_name]
  end

  def test_catalog_has_no_duplicates
    assert_equal CLIENT_NAMES.size, CLIENT_NAMES.uniq.size
    assert_equal USER_AGENTS.size, USER_AGENTS.uniq.size
  end

  private

  def assert_client_identity(name, event)
    refute_nil event, "no event published for #{name.inspect}"
    assert_equal name, event[:client_name]
    assert_equal CLIENT_VERSION, event[:client_version]
  end

  def call_after_handshake(name)
    tracked_call do |server|
      server.handle({
        jsonrpc: "2.0", id: 2, method: "tools/call",
        params: {name: "echo", arguments: {msg: "hi", session_id: "start"}}
      }, session: handshake(server, name))
    end
  end

  # Without a session `server.handle` has nowhere to keep the clientInfo from the
  # handshake, so we use a real `ServerSession`, like stdio does.
  def handshake(server, name)
    session = MCP::ServerSession.new(server: server, transport: Object.new)
    init = server.handle({
      jsonrpc: "2.0", id: 1, method: "initialize",
      params: {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: name, version: CLIENT_VERSION}}
    }, session: session)
    refute_nil init[:result], "initialize failed: #{init[:error].inspect}"
    session
  end

  def call_with_meta(meta)
    tracked_call { |server| call_tool_with_meta(server, "echo", {msg: "hi", session_id: "start"}, meta) }
  end

  # Makes the call from inside `TransportHook#call`, like the HTTP transport does, so
  # the header comes from a Rack env and we don't just pass it in.
  def call_through_transport_hook(env)
    test = self
    tracked_call do |server|
      base = Class.new do
        define_method(:call) { |_env| [200, {}, [test.send(:call_tool, server, "echo", {msg: "hi"})]] }
      end
      hooked = Class.new(base) { prepend AgentCat::RequestContext::TransportHook }
      hooked.new.call(env.merge("REQUEST_METHOD" => "POST", "CONTENT_TYPE" => "application/json"))[2].first
    end
  end

  # Fresh tracked server; the block makes the `tools/call` and returns its response.
  # Gives back the event that call published.
  def tracked_call
    server = build_server
    client = track(server, project_id: PROJECT_ID)

    response = yield(server)
    refute_nil response[:result], "tools/call failed: #{response[:error].inspect}"

    AgentCat.flush(timeout: 1)
    client.last_event
  end
end
