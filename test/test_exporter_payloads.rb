require_relative "test_helper"
require "json"

# The built-in exporters send what the TypeScript SDK sends: the same URL, headers and
# body for the same event. fixtures/exporters_ts_golden.json is the TS exporters' own
# output for this event (fixtures/exporters_ts_golden.ts says how to make it again).
# Only Sentry's `sent_at` and the random second half of its transaction and error
# event ids differ from run to run, in TS too.
class ExporterPayloadsTest < Minitest::Test
  include AgentCatTestHelpers

  GOLDEN = JSON.parse(File.read(File.join(__dir__, "fixtures", "exporters_ts_golden.json"))).freeze

  # The TS event in exporters_ts_golden.ts. TS hands exporters the tags and properties
  # it sends to AgentCat; here those are #to_wire_hash's, so the TS event's properties
  # are the two agentcat_* health signals.
  def golden_event(is_error)
    AgentCat::UnredactedEvent.new(
      project_id: "proj_2pQx7Yk3LmN8vB4cD6fG1hJ9sTp",
      id: "evt_2pQx7Yk3LmN8vB4cD6fG1hJ9sTu",
      session_id: "ses_2pQx7Yk3LmN8vB4cD6fG1hJ9sTa",
      actor_id: "usr_1",
      event_type: "mcp:tools/call",
      resource_name: "echo",
      parameters: {"arguments" => {"msg" => "hello"}},
      user_intent: "testing exporters",
      response: {"content" => [{"type" => "text", "text" => "hello"}]},
      is_error: is_error,
      error: is_error ? {"message" => "boom", "type" => "RuntimeError", "stack" => "a.rb:1"} : nil,
      duration: 12,
      timestamp: "2026-01-02T03:04:05.678Z",
      server_name: "test-server",
      server_version: "1.2.3",
      client_name: "Claude Desktop",
      client_version: "0.9.0",
      agentcat_version: "9.9.9",
      identify_actor_given_id: "usr_1",
      identify_actor_name: "Ada",
      identify_data: {"plan" => "pro"},
      tags: {"env" => "test", "Team Name" => "a,b"},
      context_supplied: true
    )
  end

  def recorder
    requests = []
    [requests, ->(url, headers, body) {
      requests << {"url" => url, "headers" => headers, "body" => body}
      [200, ""]
    }]
  end

  def export(event, &build)
    requests, post = recorder
    build.call(post).export(event)
    requests
  end

  # Byte for byte: same key order, same numbers.
  def assert_same_requests(golden_name, requests)
    assert_equal GOLDEN.fetch(golden_name), requests
  end

  # TS otlp.ts:18-19 (path), 21-24 (headers), 33-59 (resource), 83-159 (span).
  def test_otlp_matches_ts
    requests = export(golden_event(true)) do |post|
      AgentCat::Exporters::Otlp.new(endpoint: "http://collector:4318/", headers: {"x-token" => "t"}, http_post: post)
    end
    assert_same_requests "otlp", requests

    body = JSON.parse(requests.first["body"])
    resource = body["resourceSpans"][0]["resource"]["attributes"]
    assert_equal({"key" => "service.name", "value" => {"stringValue" => "test-server"}}, resource[0])
    span = body["resourceSpans"][0]["scopeSpans"][0]["spans"][0]
    assert_equal "mcp:tools/call", span["name"]
    assert_equal({"code" => 2}, span["status"])
  end

  def test_otlp_success_matches_ts
    requests = export(golden_event(false)) do |post|
      AgentCat::Exporters::Otlp.new(endpoint: "http://collector:4318/v1/traces", http_post: post)
    end
    assert_same_requests "otlp_ok", requests
  end

  # TS datadog.ts:64-66 (URLs), 81-109 (headers, bodies), 126-233 (log and metrics).
  def test_datadog_matches_ts
    requests = export(golden_event(true)) do |post|
      AgentCat::Exporters::Datadog.new(api_key: "dd-key", site: "https://datadoghq.eu/", service: "svc", env: "prod", http_post: post)
    end
    assert_same_requests "datadog", requests

    assert_equal "https://http-intake.logs.datadoghq.eu/api/v2/logs", requests[0]["url"]
    assert_equal "https://api.datadoghq.eu/api/v1/series", requests[1]["url"]
    assert_equal({"DD-API-KEY" => "dd-key", "Content-Type" => "application/json"}, requests[0]["headers"])
    log = JSON.parse(requests[0]["body"]).first
    assert_equal "error", log["status"]
    assert_includes log["ddtags"], "agentcat.team_name:a_b"
    assert_equal %w[mcp.events.count mcp.event.duration mcp.errors.count],
      JSON.parse(requests[1]["body"])["series"].map { |series| series["metric"] }
  end

  # TS posthog.ts:101-102 (URL), 132-141 (request), 156-325 (capture, $exception, $ai_span).
  def test_posthog_matches_ts
    requests = export(golden_event(true)) do |post|
      AgentCat::Exporters::PostHog.new(api_key: "phc_key", host: "https://eu.i.posthog.com/", enable_ai_tracing: true, http_post: post)
    end
    assert_same_requests "posthog", requests

    batch = JSON.parse(requests.first["body"])["batch"]
    assert_equal %w[mcp_tool_call $exception $ai_span], batch.map { |event| event["event"] }
    assert_equal "agentcat_ses_2pQx7Yk3LmN8vB4cD6fG1hJ9sTa", batch[2]["properties"]["$ai_session_id"]
    assert_equal 0.012, batch[2]["properties"]["$ai_latency"]
  end

  # Sentry envelopes, with the parts that change per run taken out.
  def envelope_items(body)
    body.split("\n").map do |line|
      item = JSON.parse(line)
      item.delete("sent_at")
      item["event_id"] = item["event_id"][0, 16] if item["event_id"].is_a?(String)
      item
    end
  end

  def assert_same_envelopes(golden_name, requests)
    golden = GOLDEN.fetch(golden_name)
    assert_equal golden.map { |r| [r["url"], r["headers"]] }, requests.map { |r| [r["url"], r["headers"]] }
    golden.zip(requests).each do |expected, actual|
      assert_equal envelope_items(expected["body"]), envelope_items(actual["body"])
      assert_equal expected["body"].end_with?("\n"), actual["body"].end_with?("\n")
    end
  end

  # TS sentry.ts:338-343 (endpoint, X-Sentry-Auth), 367-454 (log, transaction, error),
  # 456-776 (payloads and envelopes).
  def test_sentry_matches_ts
    requests = export(golden_event(true)) do |post|
      AgentCat::Exporters::Sentry.new(
        dsn: "https://abc123@o1.ingest.sentry.io/42", environment: "production", release: "1.0.0",
        enable_tracing: true, http_post: post
      )
    end
    assert_same_envelopes "sentry", requests

    assert_equal "https://o1.ingest.sentry.io/api/42/envelope/", requests[0]["url"]
    assert_equal "Sentry sentry_version=7, sentry_client=agentcat/1.0.0, sentry_key=abc123",
      requests[0]["headers"]["X-Sentry-Auth"]
    assert_equal "application/x-sentry-envelope", requests[0]["headers"]["Content-Type"]
    assert_equal %w[log transaction event], requests.map { |r| JSON.parse(r["body"].lines[1])["type"] }
    # The log's event id is the span id twice (sentry.ts:464-465), so it doesn't change.
    span_id = AgentCat::Exporters::TraceContext.span_id("evt_2pQx7Yk3LmN8vB4cD6fG1hJ9sTu")
    assert_equal span_id * 2, JSON.parse(requests[0]["body"].lines[0])["event_id"]
    error = JSON.parse(requests[2]["body"].lines[2])
    assert_equal({"type" => "RuntimeError", "value" => "boom", "mechanism" => {"type" => "mcp_tool_call", "handled" => false}},
      error["exception"]["values"][0])
    assert_equal({"source" => "agentcat", "environment" => "production", "release" => "1.0.0"},
      error["tags"].slice("source", "environment", "release"))
  end

  def test_sentry_success_sends_only_the_log_like_ts
    requests = export(golden_event(false)) do |post|
      AgentCat::Exporters::Sentry.new(dsn: "http://abc123@localhost:9000/sub/7", http_post: post)
    end
    assert_same_envelopes "sentry_ok", requests
    assert_equal "http://localhost:9000/sub/api/7/envelope/", requests[0]["url"]
  end

  # TS posthog.ts:13-59 (toUUIDv7). Values printed by TS's own toUUIDv7: a KSUID, the
  # largest KSUID, a 27-char value above 160 bits (TS's parse throws) and a non-KSUID.
  def test_uuid_v7_matches_ts
    {
      "ses_2pQx7Yk3LmN8vB4cD6fG1hJ9sTa" => "01936dad-e448-715a-9cc1-2d6d24352735",
      "ses_aWgEPTl1tmebfsQzFP4bxwgy80V" => "052df680-ac18-70fb-a3ad-b18287c0f14b",
      "ses_zzzzzzzzzzzzzzzzzzzzzzzzzzz" => "824c5521-0b85-7994-816a-e1cc13ecbe70",
      "customer-session-42" => "99f22956-c2b7-76f1-aac5-f56cb5976091"
    }.each do |id, uuid|
      assert_equal uuid, AgentCat::Exporters::TraceContext.uuid_v7(id), id
    end
  end
end
