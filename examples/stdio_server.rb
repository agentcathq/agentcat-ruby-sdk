# Minimal stdio MCP server instrumented with AgentCat.
#
#   AGENTCAT_PROJECT_ID=proj_... AGENTCAT_API_KEY=... bundle exec ruby examples/stdio_server.rb
#
# Without AGENTCAT_PROJECT_ID the server still runs; sessions and the `get_more_tools`
# helper are installed but no events are published.
require "mcp"
require "mcp/server/transports/stdio_transport"
require_relative "../lib/agentcat"

echo = MCP::Tool.define(
  name: "echo",
  description: "Echo a message back",
  input_schema: {type: "object", properties: {msg: {type: "string"}}, required: ["msg"]}
) do |msg:, server_context: nil|
  MCP::Tool::Response.new([{type: "text", text: msg}])
end

server = MCP::Server.new(name: "example-stdio", version: "0.1.0", tools: [echo])
AgentCat.track(server, ENV["AGENTCAT_PROJECT_ID"])

MCP::Server::Transports::StdioTransport.new(server).open
