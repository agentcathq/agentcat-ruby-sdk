# Minimal Streamable HTTP MCP server instrumented with AgentCat — the Ruby
# equivalent of the Python `server.run(transport="streamable-http")` and Go
# `http.ListenAndServe` examples. No Rails, no application framework.
#
#   AGENTCAT_PROJECT_ID=proj_... AGENTCAT_API_KEY=... \
#     bundle exec ruby examples/http_server.rb
#
# Then point any MCP client at http://127.0.0.1:8080/mcp. Without
# AGENTCAT_PROJECT_ID the server still runs but publishes no events.
require "mcp"
require "mcp/server/transports/streamable_http_transport"
require_relative "../lib/agentcat"

# `token` is this app's own auth parameter, not an AgentCat concept — the identify hook
# below just reads it back out of `arguments` to resolve who's calling.
echo = MCP::Tool.define(
  name: "echo",
  description: "Echo a message back",
  input_schema: {type: "object", properties: {msg: {type: "string"}, token: {type: "string"}}, required: ["msg"]}
) do |msg:, token: nil, server_context: nil|
  MCP::Tool::Response.new([{type: "text", text: msg}])
end

reverse = MCP::Tool.define(
  name: "reverse",
  description: "Reverse the input text",
  input_schema: {type: "object", properties: {text: {type: "string"}, token: {type: "string"}}, required: ["text"]}
) do |text:, token: nil|
  MCP::Tool::Response.new([{type: "text", text: text.reverse}])
end

server = MCP::Server.new(
  name: "example-http",
  title: "Example HTTP MCP Server",
  version: "0.1.0",
  tools: [echo, reverse]
)

# Stand-in for a real user directory. Swap for a lookup against your own auth system.
USERS_BY_TOKEN = {
  "demo-token" => {id: "user_1", name: "Demo User", org_id: "org_1"}
}.freeze

# Runs on every tool call, ahead of the handler. Resolves the caller to a real user when
# possible; if you can't resolve one, return a stable anonymized id (e.g. a hash of the
# token) instead of nil, so repeat calls from the same caller still roll up to one actor.
# It gets one frozen AgentCat::ToolCall: the arguments, the HTTP headers, the client's name...
identify = lambda do |tool_call|
  token = tool_call.arguments["token"] || tool_call.headers["authorization"]&.delete_prefix("Bearer ")
  user = USERS_BY_TOKEN[token]
  next nil unless user

  AgentCat::UserIdentity.new(user_id: user[:id], user_name: user[:name], user_data: {org_id: user[:org_id]})
end

# One line to add analytics, exactly like Python/Go.
AgentCat.track(server, ENV["AGENTCAT_PROJECT_ID"], AgentCat::Options.new(identify: identify))

transport = MCP::Server::Transports::StreamableHTTPTransport.new(server)

require "rackup"
require "rack/handler/puma"
port = Integer(ENV.fetch("PORT", "8080"))
warn "MCP server listening on http://127.0.0.1:#{port}/mcp"
Rackup::Handler::Puma.run(transport, Host: "127.0.0.1", Port: port)
