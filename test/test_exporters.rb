require_relative "test_helper"
require "json"
require "socket"

class ExportersTest < Minitest::Test
  include AgentCatTestHelpers

  # A real loopback HTTP/1.1 server for exercising `Base#http_post`'s actual `Net::HTTP`
  # path — every other exporter test injects a fake `http_post:` and never runs it. Yields
  # the server's base URL, then joins the handler thread and returns what it captured
  # alongside the block's own return value.
  def with_local_http_server(status: 200, response_body: "{}")
    server = TCPServer.new("127.0.0.1", 0)
    port = server.addr[1]
    captured = {}

    thread = Thread.new do
      client = server.accept
      captured[:request_line] = client.gets
      headers = {}
      while (line = client.gets) && line != "\r\n"
        key, value = line.split(":", 2)
        headers[key.strip] = value.strip if key && value
      end
      captured[:headers] = headers
      length = headers["Content-Length"].to_i
      captured[:body] = (length > 0) ? client.read(length) : ""

      client.write("HTTP/1.1 #{status} status\r\nContent-Type: application/json\r\n" \
                    "Content-Length: #{response_body.bytesize}\r\nConnection: close\r\n\r\n#{response_body}")
      client.close
    end

    result = yield "http://127.0.0.1:#{port}"
    thread.join(2)
    [result, captured]
  ensure
    server&.close
  end

  class RecordingExporter
    attr_reader :events

    def initialize
      @events = []
    end

    def export(event)
      @events << event
    end
  end

  class FakeSpan
    attr_accessor :status
    attr_reader :attributes, :finished

    def initialize
      @status = nil
      @attributes = {}
      @finished = nil
    end

    def set_attribute(key, value)
      @attributes[key] = value
    end

    def finish(end_timestamp: nil)
      @finished = end_timestamp
    end
  end

  class FakeTracer
    attr_reader :calls

    def initialize
      @calls = []
    end

    def start_span(name, kind: nil, attributes: nil, start_timestamp: nil)
      span = FakeSpan.new
      @calls << {name: name, kind: kind, attributes: attributes || {}, start_timestamp: start_timestamp, span: span}
      span
    end
  end

  def build_event(is_error: false)
    AgentCat::UnredactedEvent.new(
      project_id: PROJECT_ID,
      id: AgentCat::EventId.mint,
      session_id: "ses_exporttest0000000000000000000",
      actor_id: "usr_1",
      event_type: "mcp:tools/call",
      resource_name: "echo",
      parameters: {"msg" => "hello"},
      user_intent: "testing exporters",
      response: {content: []},
      is_error: is_error,
      error: is_error ? {"type" => "RuntimeError", "message" => "boom"} : nil,
      duration: 12,
      timestamp: Time.now.utc.iso8601(3),
      server_name: "test-server",
      agentcat_version: AgentCat::VERSION,
      tags: {"env" => "test"},
      context_supplied: true
    )
  end

  # --- Exporters.dispatch ---

  def test_dispatch_forwards_to_export_and_call_responders
    a = RecordingExporter.new
    b = RecordingExporter.new
    callable = Class.new do
      attr_reader :events

      def initialize
        @events = []
      end

      def call(event)
        @events << event
      end
    end.new
    event = build_event

    AgentCat::Exporters.dispatch([a, b, callable, Object.new], event)

    assert_equal [event], a.events
    assert_equal [event], b.events
    assert_equal [event], callable.events
  end

  def test_dispatch_contains_one_failing_exporter
    boom = Object.new
    def boom.export(_event)
      raise "broken"
    end
    recording = RecordingExporter.new
    event = build_event

    AgentCat::Exporters.dispatch([boom, recording], event)

    assert_equal [event], recording.events
  end

  # --- pipeline: exporters run regardless of project_id ---

  def test_nil_project_id_runs_exporters_with_no_api_traffic
    server = build_server
    exporter = RecordingExporter.new
    client = track(server, exporters: [exporter])

    tool_result(server, "echo", {msg: "hello", context: "testing"})

    assert_empty client.events
    assert_equal 1, exporter.events.size
    assert_nil exporter.events.first.project_id
  end

  def test_project_id_runs_exporters_and_posts_to_the_api
    server = build_server
    exporter = RecordingExporter.new
    client = track(server, project_id: PROJECT_ID, exporters: [exporter])

    tool_result(server, "echo", {msg: "hello", context: "testing"})

    assert_equal 1, client.events.size
    assert_equal 1, exporter.events.size
    assert_equal PROJECT_ID, exporter.events.first.project_id
  end

  # --- Base#http_post (real HTTP, no injected stub — every exporter test below fakes this) ---

  def test_http_post_sends_a_real_request_and_parses_a_successful_response
    base = AgentCat::Exporters::Base.new

    (status, body), captured = with_local_http_server(status: 201, response_body: '{"ok":true}') do |url|
      base.http_post("#{url}/events", {"Content-Type" => "application/json", "X-Test" => "1"}, '{"hello":"world"}')
    end

    assert_equal 201, status
    assert_equal '{"ok":true}', body
    assert_match(%r{\APOST /events HTTP/1\.1}, captured[:request_line])
    assert_equal "application/json", captured[:headers]["Content-Type"]
    assert_equal "1", captured[:headers]["X-Test"]
    assert_equal '{"hello":"world"}', captured[:body]
  end

  def test_http_post_returns_non_2xx_status_without_raising
    base = AgentCat::Exporters::Base.new

    (status, body), = with_local_http_server(status: 500, response_body: "boom") do |url|
      base.http_post(url, {}, "{}")
    end

    assert_equal 500, status
    assert_equal "boom", body
  end

  # --- Exporters.dispatch: things that aren't exporters ---

  def test_dispatch_warns_about_an_object_that_is_not_an_exporter
    log = capture_log { AgentCat::Exporters.dispatch([Object.new], build_event) }

    assert_match(/\AWARN: exporter Object does not respond to #export or #call; it is ignored/, log)
  end

  # --- hash form (TS's `{type: ...}` configs) ---

  def resolve(*entries)
    AgentCat::Exporters.resolve(entries)
  end

  def test_hash_form_builds_each_type_with_snake_case_keys
    otlp, datadog, sentry, posthog = resolve(
      {type: "otlp", endpoint: "http://collector:4318", headers: {"x-token" => "t"}},
      {type: :datadog, api_key: "k", site: "datadoghq.eu", service: "svc", env: "prod"},
      {"type" => "sentry", "dsn" => "https://abc@o1.ingest.sentry.io/42", "enable_tracing" => true},
      {"type" => "posthog", "api_key" => "phc", "host" => "https://eu.i.posthog.com", "enable_ai_tracing" => true}
    )

    assert_instance_of AgentCat::Exporters::Otlp, otlp
    assert_equal "http://collector:4318/v1/traces", otlp.endpoint
    assert_equal "t", otlp.headers["x-token"]
    assert_instance_of AgentCat::Exporters::Datadog, datadog
    assert_equal "https://http-intake.logs.datadoghq.eu/api/v2/logs", datadog.logs_url
    assert_instance_of AgentCat::Exporters::Sentry, sentry
    assert_equal "https://o1.ingest.sentry.io/api/42/envelope/", sentry.endpoint
    assert_instance_of AgentCat::Exporters::PostHog, posthog
    assert_equal "https://eu.i.posthog.com/batch", posthog.batch_url
    [otlp, datadog, sentry, posthog].each { |exporter| assert_nil exporter.setup_error }
  end

  def test_hash_form_takes_ts_camel_case_keys
    requests = []
    post = ->(url, headers, body) {
      requests << [url, headers, body]
      [200, ""]
    }
    datadog, sentry, posthog = resolve(
      {type: "datadog", apiKey: "dd-key", site: "datadoghq.com", service: "svc", http_post: post},
      {type: "sentry", dsn: "https://abc@o1.ingest.sentry.io/42", enableTracing: true, http_post: post},
      {type: "posthog", apiKey: "phc", enableAITracing: true, http_post: post}
    )

    datadog.export(build_event)
    assert_equal "dd-key", requests.last[1]["DD-API-KEY"]
    requests.clear
    sentry.export(build_event)
    assert_equal 2, requests.size, "enableTracing sends a transaction after the log"
    requests.clear
    posthog.export(build_event)
    assert_equal "https://us.i.posthog.com/batch", requests.last[0]
    assert_equal "phc", JSON.parse(requests.last[2])["api_key"]
    assert_equal "$ai_span", JSON.parse(requests.last[2])["batch"].last["event"]
  end

  def test_unknown_or_missing_type_logs_one_error_and_is_skipped
    resolved = nil
    log = capture_log { resolved = resolve({type: "newrelic", api_key: "k"}, {api_key: "k"}) }

    assert_empty resolved
    assert_equal 2, log.lines.size
    assert_match(/\AERROR: Unknown exporter type: "newrelic" in Options#exporters\[0\]/, log.lines[0])
    assert_match(/\AERROR: Unknown exporter type: none in Options#exporters\[1\]/, log.lines[1])
  end

  def test_a_hash_with_a_wrong_value_type_logs_one_error_and_is_skipped
    resolved = nil
    log = capture_log(level: Logger::WARN) { resolved = resolve({type: "datadog", api_key: 42, site: "datadoghq.com", service: "s"}) }

    assert_empty resolved
    assert_equal 1, log.lines.size
    assert_match(/\AERROR: Failed to initialize exporter Options#exporters\[0\] \(datadog\) with TypeError/, log)
  end

  def test_unknown_hash_keys_warn_and_the_exporter_still_builds
    resolved = nil
    log = capture_log { resolved = resolve({type: "otlp", endpoint: "http://c", protocol: "grpc"}) }

    assert_instance_of AgentCat::Exporters::Otlp, resolved.first
    assert_match(/\AWARN: Unknown AgentCat option exporters\[0\]\.protocol ignored/, log)
  end

  def test_an_entry_that_is_not_an_exporter_warns_and_is_skipped
    exporter = RecordingExporter.new
    resolved = nil
    log = capture_log { resolved = resolve("datadog", exporter) }

    assert_equal [exporter], resolved
    assert_match(/\AWARN: Options#exporters\[0\] must respond to #export or #call, or be a Hash with a type, got String/, log)
  end

  def test_options_resolve_the_hash_form
    options = AgentCat::Options.new(exporters: [{type: "posthog", api_key: "phc"}])

    assert_instance_of AgentCat::Exporters::PostHog, options.exporters.first
  end

  # --- URL rules ---

  def test_datadog_strips_the_scheme_and_trailing_slash_from_site
    ["datadoghq.eu", "https://datadoghq.eu", "http://datadoghq.eu/"].each do |site|
      exporter = AgentCat::Exporters::Datadog.new(api_key: "k", site: site, service: "s")
      assert_equal "https://http-intake.logs.datadoghq.eu/api/v2/logs", exporter.logs_url, site
      assert_equal "https://api.datadoghq.eu/api/v1/series", exporter.metrics_url, site
    end
  end

  def test_posthog_host_keeps_its_scheme_and_a_bare_host_gets_https
    {
      nil => "https://us.i.posthog.com/batch",
      "https://eu.i.posthog.com" => "https://eu.i.posthog.com/batch",
      "https://eu.i.posthog.com/" => "https://eu.i.posthog.com/batch",
      "http://localhost:8000" => "http://localhost:8000/batch",
      "eu.i.posthog.com" => "https://eu.i.posthog.com/batch"
    }.each do |host, url|
      assert_equal url, AgentCat::Exporters::PostHog.new(api_key: "k", host: host).batch_url, host.inspect
    end
  end

  def test_otlp_appends_v1_traces_like_ts
    {
      "http://c:4318" => "http://c:4318/v1/traces",
      "http://c:4318/" => "http://c:4318/v1/traces",
      "http://c:4318//" => "http://c:4318/v1/traces",
      "http://c:4318/v1/traces" => "http://c:4318/v1/traces",
      "http://c:4318/v1/traces/" => "http://c:4318/v1/traces",
      "http://c/otel" => "http://c/otel/v1/traces"
    }.each do |endpoint, url|
      assert_equal url, AgentCat::Exporters::Otlp.new(endpoint: endpoint).endpoint, endpoint
    end
  end

  # --- Sentry DSN ---

  def test_sentry_parses_the_dsn_like_ts
    {
      "https://abc123@o1.ingest.sentry.io/42" => "https://o1.ingest.sentry.io/api/42/envelope/",
      "http://abc@localhost:9000/7" => "http://localhost:9000/api/7/envelope/",
      "https://abc@sentry.example.com/prefix/path/7" => "https://sentry.example.com/prefix/path/api/7/envelope/"
    }.each do |dsn, endpoint|
      assert_equal endpoint, AgentCat::Exporters::Sentry.new(dsn: dsn).endpoint, dsn
    end
  end

  def test_sentry_with_an_invalid_dsn_logs_an_error_without_the_dsn
    exporter = nil
    log = capture_log { exporter = AgentCat::Exporters::Sentry.new(dsn: "https://NOTHEX@sentry.io/abc") }

    assert_match(/invalid dsn/, exporter.setup_error)
    assert_equal 1, log.lines.size
    refute_includes log, "NOTHEX"
  end

  # --- setup errors ---

  def test_missing_required_keys_log_an_error_instead_of_raising
    log = capture_log do
      assert_match(/api_key, site, service/, AgentCat::Exporters::Datadog.new.setup_error)
      assert_match(/site/, AgentCat::Exporters::Datadog.new(api_key: "k", service: "s").setup_error)
      assert AgentCat::Exporters::PostHog.new(api_key: nil).setup_error
      assert AgentCat::Exporters::Sentry.new(dsn: "").setup_error
      assert AgentCat::Exporters::Otlp.new.setup_error
    end
    assert_equal 5, log.lines.size
    assert(log.lines.all? { |line| line.start_with?("ERROR: ") && line.include?("This exporter is off") })
  end

  def test_an_exporter_that_is_off_posts_nothing
    exporter = AgentCat::Exporters::Datadog.new(api_key: "", site: "datadoghq.com", service: "s", http_post: ->(*) { flunk "must not post" })
    exporter.export(build_event)
  end

  # --- failures ---

  def test_a_non_2xx_response_raises_after_every_request_went_out
    requests = 0
    exporter = AgentCat::Exporters::Datadog.new(
      api_key: "k", site: "datadoghq.com", service: "s",
      http_post: ->(*) {
        requests += 1
        [403, "forbidden"]
      }
    )

    error = assert_raises(RuntimeError) { exporter.export(build_event) }
    assert_match(/Datadog returned HTTP 403/, error.message)
    assert_equal 2, requests, "the metrics request still goes out after the logs request fails"

    log = capture_log { AgentCat::Exporters.dispatch([exporter], build_event) }
    assert_match(/ERROR: exporter AgentCat::Exporters::Datadog failed with RuntimeError/, log)
  end

  def test_sentry_sends_nothing_but_the_log_for_a_successful_call_without_tracing
    bodies = []
    exporter = AgentCat::Exporters::Sentry.new(dsn: "https://abc@o1.ingest.sentry.io/42", http_post: ->(_url, _headers, body) {
      bodies << body
      [200, ""]
    })

    exporter.export(build_event)
    assert_equal ["log"], bodies.map { |body| JSON.parse(body.lines[1])["type"] }
    exporter.export(build_event(is_error: true))
    assert_equal %w[log log event], bodies.map { |body| JSON.parse(body.lines[1])["type"] }
  end

  # --- Otlp through your own tracer (Ruby only) ---

  def test_otlp_with_a_tracer_emits_the_ts_span_through_it
    tracer = FakeTracer.new
    exporter = AgentCat::Exporters::Otlp.new(tracer: tracer)
    event = build_event(is_error: true)

    exporter.export(event)

    call = tracer.calls.first
    assert_equal "mcp:tools/call", call[:name]
    assert_equal :server, call[:kind] # no opentelemetry gem installed -> fallback
    assert_equal "agentcat", call[:attributes]["source"]
    assert_equal "echo", call[:attributes]["mcp.resource_name"]
    assert_equal "test", call[:attributes]["agentcat.tag.env"]
    assert_equal "ERROR", call[:span].attributes["otel.status_code"]
    assert_in_delta call[:start_timestamp] + 0.012, call[:span].finished, 0.0001
  end
end
