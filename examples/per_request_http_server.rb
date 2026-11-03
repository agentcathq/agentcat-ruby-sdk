# A "stateless" topology: rather than one long-lived MCP::Server, a fresh one is built and
# tracked on every incoming HTTP request — the pattern serverless/per-request deployments
# use. No state carries over between requests, including which tools were ever listed.
#
#   AGENTCAT_PROJECT_ID=proj_... AGENTCAT_API_KEY=... \
#     bundle exec ruby examples/per_request_http_server.rb
#
# A client that discovered tools against one request can call a tool directly on the next
# one without listing again — AgentCat still instruments it before the call runs, since
# `track()`'s dispatch hook re-checks on a `tools/call` naming a tool it hasn't wrapped yet,
# not only on `tools/list`.
require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "../lib/agentcat"

def build_tracked_server
  echo = MCP::Tool.define(
    name: "echo",
    description: "Echo a message back",
    input_schema: {type: "object", properties: {msg: {type: "string"}}, required: ["msg"]}
  ) do |msg:, server_context: nil|
    MCP::Tool::Response.new([{type: "text", text: msg}])
  end

  server = MCP::Server.new(name: "example-per-request", version: "0.1.0", tools: [echo])
  AgentCat.track(server, ENV["AGENTCAT_PROJECT_ID"])
  server
end

# `StreamableHTTPTransport#call` is itself a Rack app, so building a fresh tracked server
# per request is just a matter of building a fresh transport around one per call.
app = lambda do |env|
  MCP::Server::Transports::StreamableHTTPTransport.new(build_tracked_server).call(env)
end

require "rackup"
require "rack/handler/puma"
port = Integer(ENV.fetch("PORT", "8080"))
warn "Per-request MCP server listening on http://127.0.0.1:#{port}/mcp"
Rackup::Handler::Puma.run(app, Host: "127.0.0.1", Port: port)
