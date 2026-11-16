# Line coverage, only when asked for: `COVERAGE=1 bundle exec rake`. CI sets it on the
# unit suite and fails below the minimum. Must start before anything in lib/ loads.
if ENV["COVERAGE"] == "1"
  require "simplecov"
  SimpleCov.start do
    enable_coverage :line
    track_files "lib/**/*.rb"
    add_filter "/test/"
    add_filter "/scripts/"
    # Fail CI if a change drops line coverage below 95%.
    minimum_coverage line: 95
  end
end

require "sorbet-runtime"
# Turns the `.checked(:tests)` sigs sprinkled through the SDK (interceptor, session
# manager, client, hooks) into real runtime checks for this process. Off by default —
# without this, those sigs are never enforced anywhere, in tests or in production. Must
# run before anything requires the gem, since the first call to a `.checked(:tests)`
# method locks the setting in.
T.unsafe(T::Private).const_get(:RuntimeLevels).enable_checking_in_tests

require "minitest/autorun"
require "stringio"
require "json"
require "socket"

# Minitest is loaded, so AgentCat's test mode would turn the SDK off here like it does in
# a customer's suite. The suite tests the real path, so force it on. Test mode
# itself is covered in test_test_mode.rb, which unsets this per test. Diagnostics stay
# off unless a test sets AGENTCAT_DISABLE_DIAGNOSTICS=false.
ENV["AGENTCAT_ENABLED"] = "true"
require "mcp"
require_relative "../lib/agentcat"

AgentCat.logger = Logger.new(File::NULL)

PROJECT_ID = "proj_3Ijx2rJlArrIB9Sl9tDTFxpCB0K"

# In-memory replacement for AgentCat::Client.
class RecordingClient
  attr_reader :events

  def initialize
    @events = []
  end

  def post_event(event)
    @events << event
    {"status" => "accepted"}
  end

  def last_event
    @events.last
  end
end

# In-memory replacement for the server info sender: records each body and answers with
# the next of `statuses` (the last one repeats). Nothing leaves the process.
class ServerInfoRecorder
  def initialize(statuses = [202])
    @statuses = statuses.dup
    @bodies = []
    @mutex = Mutex.new
  end

  def bodies
    @mutex.synchronize { @bodies.dup }
  end

  def post_server_info(body)
    @mutex.synchronize do
      @bodies << JSON.parse(JSON.generate(body))
      (@statuses.size > 1) ? @statuses.shift : @statuses.first
    end
  end
end

# Every test starts with a recorder in place of the real sender, so no heartbeat reaches
# the network, whatever client a test tracks its server with.
AgentCat::ServerInfo.sender = ServerInfoRecorder.new

# A loopback port that nothing listens on. The default base URL of the suite: a request
# that leaks past a test's own setup goes nowhere. A test that changes the variable
# sets it back to this.
CLOSED_API_URL = begin
  listener = TCPServer.new("127.0.0.1", 0)
  "http://127.0.0.1:#{listener.addr[1]}"
ensure
  listener&.close
end
ENV["AGENTCAT_API_URL"] = CLOSED_API_URL

module AgentCatTestHelpers
  ECHO_SCHEMA = {type: "object", properties: {msg: {type: "string"}}, required: ["msg"]}.freeze

  def setup
    AgentCat.reset!
    AgentCat::ServerInfo.sender = ServerInfoRecorder.new
  end

  def server_info_bodies
    wait_for_server_info
    AgentCat::ServerInfo.sender.bodies
  end

  # Joins every heartbeat thread still running, so a test reads the recorder after the
  # work. `timeout: nil` waits for each thread to end.
  def wait_for_server_info(timeout: 5)
    Thread.list.select { |thread| thread.name == AgentCat::ServerInfo::THREAD_NAME }.each { |thread| thread.join(timeout) }
  end

  # Runs the block with `sender` in place of the recorder. Every heartbeat thread has
  # ended before the previous sender comes back.
  def with_server_info_sender(sender)
    previous = AgentCat::ServerInfo.sender
    AgentCat::ServerInfo.sender = sender
    yield
  ensure
    wait_for_server_info(timeout: nil)
    AgentCat::ServerInfo.sender = previous
  end

  # A sender that cannot send: the heartbeat stops before it calls a list handler or a
  # hook, for a test that counts the calls of a customer hook. `restore_server_info`
  # puts the recorder back.
  def turn_off_server_info
    AgentCat::ServerInfo.sender = Object.new
  end

  def restore_server_info
    wait_for_server_info(timeout: nil)
    AgentCat::ServerInfo.sender = ServerInfoRecorder.new
  end

  # Moves the first check of this memory `seconds` into the past, as in a process that
  # has run for that long.
  def age_server_info_memory(seconds = 60)
    AgentCat::ServerInfo.instance_variable_set(:@first_check_at, AgentCat::ServerInfo.now - seconds)
  end

  def echo_tool(name: "echo", description: "Echo a message", input_schema: ECHO_SCHEMA, **definition, &block)
    block ||= ->(msg:, server_context: nil) { MCP::Tool::Response.new([{type: "text", text: msg}]) }
    MCP::Tool.define(name: name, description: description, input_schema: input_schema, **definition, &block)
  end

  def build_server(tools: [echo_tool], name: "test-server", version: "1.2.3")
    MCP::Server.new(name: name, version: version, tools: tools)
  end

  def track(server, project_id: nil, client: RecordingClient.new, **options)
    AgentCat.track(server, project_id, AgentCat::Options.new(client: client, **options))
    client
  end

  # Runs the block with AgentCat.logger writing to a string, and returns what it logged
  # (one "LEVEL: message" line per entry). `level` is the lowest level kept.
  def capture_log(level: Logger::DEBUG)
    io = StringIO.new
    previous = AgentCat.logger
    logger = Logger.new(io, level: level)
    logger.formatter = proc { |severity, _time, _progname, message| "#{severity}: #{message}\n" }
    AgentCat.logger = logger
    yield
    io.string
  ensure
    AgentCat.logger = previous
  end

  def list_tools(server)
    server.handle({jsonrpc: "2.0", id: 1, method: "tools/list", params: {}})[:result][:tools]
  end

  def listed_tool(server, name)
    list_tools(server).find { |tool| tool[:name] == name }
  end

  # `session_id` is a required schema field once AgentCat injects it, so most tests (which
  # aren't testing session behavior at all) need *some* valid value to get past the `mcp`
  # gem's own schema validation before ever reaching AgentCat's interceptor. Default to
  # `"start"` only when the tool's current schema actually requires it — modes that don't
  # inject it at all (`resolve_session_id`, `stateless`) must not get a stray `session_id`
  # argument their handler was never meant to see. Pass `session_id:` explicitly to test
  # session behavior itself; it always wins over this default.
  def call_tool(server, name, arguments = {})
    arguments = default_session_id(server, name).merge(arguments)
    server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: name, arguments: arguments}})
  end

  def default_session_id(server, name)
    required = listed_tool(server, name)&.dig(:inputSchema, :required) || []
    required.include?("session_id") ? {session_id: "start"} : {}
  end

  def tool_result(server, name, arguments = {})
    response = call_tool(server, name, arguments)
    refute_nil response[:result], "tools/call failed: #{response[:error].inspect}"
    AgentCat.flush(timeout: 1)
    response[:result]
  end

  # `tools/call` carrying a raw request `_meta` hash (the SEP-2575 reserved keys). Goes
  # through the real gem dispatch so a genuine `MCP::ServerContext` is built.
  def call_tool_with_meta(server, name, arguments, meta)
    server.handle({
      jsonrpc: "2.0", id: 2, method: "tools/call",
      params: {name: name, arguments: arguments, _meta: meta}
    })
  end

  def texts_of(result)
    result[:content].map { |block| block[:text] }
  end

  def agentcat_meta(result)
    result.dig(:_meta, :agentcat)
  end

  # Mirrors `Interceptor#mint_back_text` for assertions — the mint-back block shape
  # (header line, then body) isn't one templated sentence anymore.
  def mint_back_issued_text(session_id)
    [AgentCat::Schema::MINT_BACK_HEADER_ISSUED, "session_id: #{session_id}", AgentCat::Schema::MINT_BACK_ISSUED_BODY].join("\n")
  end

  def mint_back_unrecognized_text
    [AgentCat::Schema::MINT_BACK_HEADER_UNRECOGNIZED, AgentCat::Schema::MINT_BACK_UNRECOGNIZED_BODY].join("\n")
  end
end
