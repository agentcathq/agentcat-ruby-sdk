// Writes exporters_ts_golden.json: what the TypeScript SDK's exporters send for one
// event. test/test_exporter_payloads.rb checks the Ruby exporters against it. To
// regenerate, copy this file into the root of an agentcat-typescript-sdk checkout and run:
//
//   node_modules/.bin/esbuild exporters_ts_golden.ts --bundle --platform=node --outfile=/tmp/golden.cjs
//   node /tmp/golden.cjs | grep -v '^\[agentcat\]' > exporters_ts_golden.json
//
// Generated from agentcat-typescript-sdk 2.1.1-beta.1.
import { OTLPExporter } from "./src/modules/exporters/otlp";
import { DatadogExporter } from "./src/modules/exporters/datadog";
import { SentryExporter } from "./src/modules/exporters/sentry";
import { PostHogExporter } from "./src/modules/exporters/posthog";

const calls: any[] = [];
(globalThis as any).fetch = async (url: string, init: any) => {
  calls.push({ url, headers: init.headers, body: init.body });
  return { ok: true, status: 200, text: async () => "" };
};

function event(isError: boolean): any {
  return {
    id: "evt_2pQx7Yk3LmN8vB4cD6fG1hJ9sTu",
    sessionId: "ses_2pQx7Yk3LmN8vB4cD6fG1hJ9sTa",
    projectId: "proj_2pQx7Yk3LmN8vB4cD6fG1hJ9sTp",
    eventType: "mcp:tools/call",
    timestamp: new Date("2026-01-02T03:04:05.678Z"),
    duration: 12,
    agentcatVersion: "9.9.9",
    serverName: "test-server",
    serverVersion: "1.2.3",
    clientName: "Claude Desktop",
    clientVersion: "0.9.0",
    identifyActorGivenId: "usr_1",
    identifyActorName: "Ada",
    identifyActorData: { plan: "pro" },
    resourceName: "echo",
    parameters: { arguments: { msg: "hello" } },
    response: { content: [{ type: "text", text: "hello" }] },
    userIntent: "testing exporters",
    isError,
    error: isError ? { message: "boom", type: "RuntimeError", stack: "a.rb:1" } : undefined,
    tags: { env: "test", "Team Name": "a,b" },
    properties: { agentcat_context_supplied: true, agentcat_via_get_more_tools: false },
  };
}

async function main() {
  const out: any = {};
  for (const [name, exp, isError] of [
    ["otlp", new OTLPExporter({ type: "otlp", endpoint: "http://collector:4318/", headers: { "x-token": "t" } }), true],
    ["otlp_ok", new OTLPExporter({ type: "otlp", endpoint: "http://collector:4318/v1/traces" }), false],
    ["datadog", new DatadogExporter({ type: "datadog", apiKey: "dd-key", site: "https://datadoghq.eu/", service: "svc", env: "prod" }), true],
    ["sentry", new SentryExporter({ type: "sentry", dsn: "https://abc123@o1.ingest.sentry.io/42", environment: "production", release: "1.0.0", enableTracing: true }), true],
    ["sentry_ok", new SentryExporter({ type: "sentry", dsn: "http://abc123@localhost:9000/sub/7" }), false],
    ["posthog", new PostHogExporter({ type: "posthog", apiKey: "phc_key", host: "https://eu.i.posthog.com/", enableAITracing: true }), true],
  ] as const) {
    calls.length = 0;
    await (exp as any).export(event(isError as boolean));
    out[name] = calls.map((c) => ({ ...c }));
  }
  console.log(JSON.stringify(out, null, 1));
}
main();
