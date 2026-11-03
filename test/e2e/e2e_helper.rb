require_relative "../test_helper"
require "mcp/server/transports/streamable_http_transport"
require "puma"
require "net/http"
require "json"

module E2EHelpers
  include AgentCatTestHelpers

  # The request thread only enqueues an event; a queue worker builds and delivers it a
  # little later. Reading `events` or `last_event` right after a call would race that
  # worker and see nil now and then. Every read here first waits for the queue to drain,
  # so no test has to remember to call `AgentCat.flush` itself.
  class WaitingRecordingClient < RecordingClient
    DRAIN_TIMEOUT = 5

    def events
      return super if AgentCat.flush(timeout: DRAIN_TIMEOUT)

      raise "AgentCat's event queue did not drain within #{DRAIN_TIMEOUT}s"
    end

    def last_event
      events.last
    end
  end

  # Boots a real MCP::Server behind a real Puma HTTP server on a random free port,
  # instrumented with AgentCat, and yields an E2EClient (real HTTP, real JSON-RPC framing)
  # plus the RecordingClient AgentCat publishes events to. Only event *delivery* is faked —
  # everything else (schema validation, dispatch, the streamable HTTP transport) is the
  # genuine `mcp` gem stack, not the in-process `server.handle(hash)` shortcut the rest of
  # the suite uses. That's the whole point of this tier: it catches what the shortcut can't,
  # like the `mcp` gem's own required-argument enforcement running ahead of AgentCat's code.
  def run_e2e_server(tools: [echo_tool], initialize: true, stateless: false, **options)
    recording_client = WaitingRecordingClient.new
    server = build_server(tools: tools)
    track(server, project_id: PROJECT_ID, client: recording_client, **options)

    transport = MCP::Server::Transports::StreamableHTTPTransport.new(server, stateless: stateless)
    puma = Puma::Server.new(transport)
    puma.add_tcp_listener("127.0.0.1", 0)
    puma.run
    port = puma.connected_ports.first

    client = E2EClient.new(port)
    client.initialize! if initialize
    yield client, recording_client, server
  ensure
    AgentCat.flush(timeout: 2)
    puma&.stop(true)
  end

  # A minimal real HTTP client for the Streamable HTTP transport — no mocking, genuine
  # `Net::HTTP` requests, genuine `Mcp-Session-Id` handshake.
  class E2EClient
    def initialize(port)
      @uri = URI("http://127.0.0.1:#{port}/mcp")
      @session_id = nil
      @next_id = 0
    end

    def initialize!(name: "e2e-client", version: "0.1.0")
      post({jsonrpc: "2.0", id: next_id, method: "initialize", params: {protocolVersion: "2025-06-18", capabilities: {}, clientInfo: {name: name, version: version}}}, capture_session: true)
      post({jsonrpc: "2.0", method: "notifications/initialized"})
    end

    # A second, independent client on the same server: its own connection, its own
    # session (or none, on a stateless server).
    def another_client
      E2EClient.new(@uri.port)
    end

    def list_tools
      post({jsonrpc: "2.0", id: next_id, method: "tools/list", params: {}})
    end

    def call_tool(name, arguments = {}, headers: {})
      post({jsonrpc: "2.0", id: next_id, method: "tools/call", params: {name: name, arguments: arguments}}, headers: headers)
    end

    # A `tools/call` carrying the SEP-2575 reserved `_meta` keys, for exercising the
    # stateless lifecycle where there is no `initialize` handshake to read identity from.
    # A modern envelope must be accompanied by the SEP-2575 header triple:
    # `MCP-Protocol-Version`, `Mcp-Method`, and `Mcp-Name`.
    def call_tool_with_meta(name, arguments, meta, protocol_version: nil)
      headers = protocol_version ? {
        "MCP-Protocol-Version" => protocol_version,
        "Mcp-Method" => "tools/call",
        "Mcp-Name" => name
      } : {}
      post({jsonrpc: "2.0", id: next_id, method: "tools/call", params: {name: name, arguments: arguments, _meta: meta}}, headers: headers)
    end

    private

    def next_id
      @next_id += 1
    end

    def post(body, capture_session: false, headers: {})
      request = Net::HTTP::Post.new(@uri)
      request["Content-Type"] = "application/json"
      request["Accept"] = "application/json, text/event-stream"
      request["Mcp-Session-Id"] = @session_id if @session_id
      headers.each { |name, value| request[name] = value }
      request.body = JSON.generate(body)

      response = Net::HTTP.start(@uri.host, @uri.port) { |http| http.request(request) }
      @session_id ||= response["Mcp-Session-Id"] if capture_session

      return nil if response.body.to_s.strip.empty?

      raw = response.body.to_s.delete_prefix("data: ").strip
      JSON.parse(raw, symbolize_names: true)
    end
  end
end
