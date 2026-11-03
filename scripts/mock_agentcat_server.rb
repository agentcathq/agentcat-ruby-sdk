# Local stand-in for the AgentCat events API (stdlib-only, no webrick).
#
#   bundle exec ruby scripts/mock_agentcat_server.rb
#   AGENTCAT_API_URL=http://127.0.0.1:4567 bundle exec ruby examples/stdio_server.rb
require "socket"
require "json"

port = (ENV["PORT"] || "4567").to_i
server = TCPServer.new("127.0.0.1", port)
puts "Mock AgentCat API listening on http://127.0.0.1:#{port}"

loop do
  socket = server.accept
  Thread.new(socket) do |client|
    request_line = client.gets.to_s
    method, path = request_line.split(" ")[0], request_line.split(" ")[1]
    headers = {}
    while (line = client.gets)
      line = line.chomp
      break if line.empty?
      key, value = line.split(":", 2)
      headers[key.strip.downcase] = value.to_s.strip
    end

    body = ""
    if headers["content-length"]
      body = client.read(headers["content-length"].to_i)
    end

    if method == "POST" && path.to_s.start_with?("/v1/public/events/")
      puts "Received event: #{body}"
      status = 200
      resp_body = {status: "accepted"}.to_json
    else
      status = 404
      resp_body = {error: "not found"}.to_json
    end

    client.write("HTTP/1.1 #{status}\r\n")
    client.write("Content-Type: application/json\r\n")
    client.write("Content-Length: #{resp_body.bytesize}\r\n")
    client.write("Connection: close\r\n\r\n")
    client.write(resp_body)
  rescue => e
    puts "mock error: #{e.class}: #{e.message}"
  ensure
    begin
      client.close
    rescue
      nil
    end
  end
end
