require_relative "test_helper"
require "open3"
require "rbconfig"

# `AgentCat::RequestContext` is the ambient per-request HTTP metadata the event
# carries at `parameters.extra.requestInfo.headers`. The reference SDKs get this
# from their MCP framework; the `mcp` gem does not, so the transport hook fills it
# in. These exercise the pure env->extra conversion and the scope in isolation.
class RequestContextTest < Minitest::Test
  include AgentCatTestHelpers

  def teardown
    AgentCat::RequestContext.restore(nil)
  end

  def test_builds_request_info_headers_from_a_rack_env
    env = {
      "HTTP_USER_AGENT" => "Cursor/2.6.22",
      "HTTP_X_CORRELATION_ID" => "corr-1",
      "CONTENT_TYPE" => "application/json",
      "CONTENT_LENGTH" => "42",
      "REQUEST_METHOD" => "POST",
      "PATH_INFO" => "/mcp"
    }

    headers = AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["headers"]

    assert_equal "Cursor/2.6.22", headers["user-agent"]
    assert_equal "corr-1", headers["x-correlation-id"]
    assert_equal "application/json", headers["content-type"]
    assert_equal "42", headers["content-length"]
    # Rack's non-header env keys must not leak in as headers.
    refute headers.key?("request-method")
    refute headers.key?("path-info")
  end

  def test_returns_nil_when_there_is_nothing_to_report
    assert_nil AgentCat::RequestContext.extra_from_env(nil)
    assert_nil AgentCat::RequestContext.extra_from_env("not a hash")
    assert_nil AgentCat::RequestContext.extra_from_env({"REQUEST_METHOD" => "POST"})
  end

  # One string per header. Repeated values are joined with ", ", the way a
  # web server joins repeated request headers.
  def test_joins_multi_valued_headers_into_one_string
    env = {"HTTP_X_FORWARDED_FOR" => ["1.1.1.1", "2.2.2.2"]}

    assert_equal "1.1.1.1, 2.2.2.2", AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["headers"]["x-forwarded-for"]
  end

  def test_stringifies_non_string_values_and_skips_nil_ones
    env = {"HTTP_X_RETRY_COUNT" => 3, "HTTP_X_EMPTY" => nil, "HTTP_X_FORWARDED_FOR" => [1, "2.2.2.2"]}

    headers = AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["headers"]

    assert_equal({"x-retry-count" => "3", "x-forwarded-for" => "1, 2.2.2.2"}, headers)
  end

  # Two env keys can land on the same header name (`X_Trace` and `X-Trace` both become
  # `x-trace`) - keep every value, joined, instead of letting the later one win.
  def test_env_keys_colliding_on_one_header_name_keep_every_value
    env = {"HTTP_X_TRACE" => "a", "HTTP_X-TRACE" => ["b", "c"]}

    assert_equal "a, b, c", AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["headers"]["x-trace"]
  end

  def test_header_names_are_lower_case
    env = {"HTTP_X_MiXeD" => "v"}

    assert_equal({"x-mixed" => "v"}, AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["headers"])
  end

  # As in TS v1, `requestInfo.url` is the full request URL, query as sent.
  def test_request_info_carries_the_full_url
    env = {
      "rack.url_scheme" => "https", "HTTP_HOST" => "mcp.example.com:8443",
      "SCRIPT_NAME" => "/app", "PATH_INFO" => "/mcp", "QUERY_STRING" => "b=2&a=1"
    }

    assert_equal "https://mcp.example.com:8443/app/mcp?b=2&a=1", AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["url"]
  end

  def test_url_prefers_the_raw_request_uri
    env = {"rack.url_scheme" => "http", "HTTP_HOST" => "localhost:9292", "REQUEST_URI" => "/mcp/?x=1", "PATH_INFO" => "/mcp"}

    assert_equal "http://localhost:9292/mcp/?x=1", AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["url"]
  end

  def test_url_falls_back_to_server_name_and_port
    env = {"rack.url_scheme" => "http", "SERVER_NAME" => "internal", "SERVER_PORT" => "8080", "PATH_INFO" => "/mcp", "QUERY_STRING" => ""}

    assert_equal "http://internal:8080/mcp", AgentCat::RequestContext.extra_from_env(env)["requestInfo"]["url"]
  end

  # No host means no URL: nothing is made up.
  def test_no_url_without_a_host
    info = AgentCat::RequestContext.extra_from_env({"HTTP_USER_AGENT" => "curl/8", "PATH_INFO" => "/mcp"})["requestInfo"]

    refute info.key?("url")
    assert_equal({"user-agent" => "curl/8"}, info["headers"])
  end

  def test_current_is_nil_outside_a_captured_request
    assert_nil AgentCat::RequestContext.current
  end

  def test_capture_and_restore_scope_the_current_extra
    extra = {"requestInfo" => {"headers" => {"user-agent" => "Claude Code"}}}

    previous = AgentCat::RequestContext.capture(extra)
    assert_equal extra, AgentCat::RequestContext.current
    assert_equal [nil, nil], previous

    AgentCat::RequestContext.restore(previous)
    assert_nil AgentCat::RequestContext.current
  end

  def test_capture_is_reentrant_and_restores_the_outer_scope
    inner = {"requestInfo" => {"headers" => {"user-agent" => "inner"}}}
    outer = {"requestInfo" => {"headers" => {"user-agent" => "outer"}}}

    AgentCat::RequestContext.capture(outer)
    previous = AgentCat::RequestContext.capture(inner)
    assert_equal inner, AgentCat::RequestContext.current

    AgentCat::RequestContext.restore(previous)
    assert_equal outer, AgentCat::RequestContext.current
  end

  # `TransportHook` is what actually runs in the `mcp` gem's transport (it's prepended to
  # the class by `install!`); these pin the scoping contract without needing a real Rack
  # request. Eager bodies dispatch inside `call`; the sessionful SSE path hands back a
  # callable body that dispatches later, so the hook must scope that too.
  def test_transport_hook_makes_headers_ambient_during_an_eager_call
    seen = nil
    base = Class.new do
      define_method(:call) do |_env|
        seen = AgentCat::RequestContext.current
        [200, {}, ["ok"]]
      end
    end
    hooked = Class.new(base) { prepend AgentCat::RequestContext::TransportHook }

    result = hooked.new.call({"HTTP_USER_AGENT" => "Codex/1", "CONTENT_TYPE" => "application/json"})

    assert_equal [200, {}, ["ok"]], result
    assert_equal "Codex/1", seen.dig("requestInfo", "headers", "user-agent")
    assert_equal "application/json", seen.dig("requestInfo", "headers", "content-type")
    assert_nil AgentCat::RequestContext.current
  end

  def test_transport_hook_scopes_a_deferred_callable_body
    seen = nil
    base = Class.new do
      define_method(:call) do |_env|
        [200, {}, proc { |_stream| seen = AgentCat::RequestContext.current }]
      end
    end
    hooked = Class.new(base) { prepend AgentCat::RequestContext::TransportHook }

    status, _headers, body = hooked.new.call({"HTTP_USER_AGENT" => "Claude Code"})
    assert_equal 200, status
    # The ambient capture must be gone once `call` returns...
    assert_nil AgentCat::RequestContext.current

    # ...and come back for the duration of the body's own invocation.
    body.call("socket")
    assert_equal "Claude Code", seen.dig("requestInfo", "headers", "user-agent")
    assert_nil AgentCat::RequestContext.current
  end

  def test_transport_hook_leaves_a_non_callable_body_untouched
    original = ["ok"]
    base = Class.new do
      define_method(:call) { |_env| [200, {}, original] }
    end
    hooked = Class.new(base) { prepend AgentCat::RequestContext::TransportHook }

    _status, _headers, body = hooked.new.call({"HTTP_USER_AGENT" => "x"})

    assert_same original, body
    assert_nil AgentCat::RequestContext.current
  end

  def test_transport_hook_restores_the_scope_when_the_wrapped_call_raises
    base = Class.new do
      def call(_env)
        raise "boom"
      end
    end
    hooked = Class.new(base) { prepend AgentCat::RequestContext::TransportHook }

    assert_raises(RuntimeError) { hooked.new.call({"HTTP_X" => "y"}) }
    assert_nil AgentCat::RequestContext.current
  end

  # The `mcp` gem doesn't depend on rack, and it autoloads its HTTP transport, which
  # raises LoadError without rack. A stdio server whose bundle has no rack must still
  # track (no headers to capture there anyway).
  def test_track_works_without_rack
    lib = File.expand_path("../lib", __dir__)
    script = <<~RUBY
      module Kernel
        alias_method :require_without_rack_block, :require
        def require(name)
          raise LoadError, "cannot load such file -- rack" if name == "rack"
          require_without_rack_block(name)
        end
      end
      require "mcp"
      require "agentcat"
      AgentCat.logger = Logger.new(File::NULL)
      server = MCP::Server.new(name: "stdio-only")
      AgentCat.track(server, nil, AgentCat::Options.new(disable_diagnostics: true))
      print "tracked"
    RUBY
    out, err, status = Open3.capture3({"AGENTCAT_ENABLED" => "true"}, RbConfig.ruby, "-I", lib, "-e", script)

    assert status.success?, err
    assert_equal "tracked", out
  end
end
