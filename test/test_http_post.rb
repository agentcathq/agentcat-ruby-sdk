require_relative "test_helper"
require "socket"

class HttpPostTest < Minitest::Test
  # `deadline:` bounds the whole request. A server that sends its status line one
  # byte at a time never trips the per-read timeout, only the total.
  def test_deadline_bounds_a_trickling_response
    server = TCPServer.new("127.0.0.1", 0)
    writer = Thread.new do
      client = server.accept
      client.readpartial(4096)
      "HTTP/1.1 200 OK\r\nX-Slow: #{"a" * 100}".each_char do |char|
        client.write(char)
        sleep 0.1
      end
    rescue IOError, SystemCallError
      nil
    end

    started = AgentCat::Clock.monotonic_now
    assert_raises(Timeout::Error) do
      AgentCat::HttpPost.call(
        "http://127.0.0.1:#{server.addr[1]}/v1/logs", {}, "{}",
        open_timeout: 0.25, read_timeout: 1, deadline: 0.5
      )
    end
    assert_operator AgentCat::Clock.monotonic_now - started, :<, 1.0
  ensure
    writer&.kill
    server&.close
  end
end
