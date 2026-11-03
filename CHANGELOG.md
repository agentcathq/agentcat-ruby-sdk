# Changelog

All notable changes to this project are documented in this file.

The format follows [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project follows [Semantic Versioning](https://semver.org/).

## [Unreleased]

## [1.0.0] - 2026-11-03

The first stable release of the SDK. From this release on, the public API
follows Semantic Versioning: a breaking change needs a new major version.

### Added

- `AgentCat.track(server, project_id, options)`: records each tool call of an
  `MCP::Server` from the official `mcp` gem as an AgentCat event. It works
  over stateless HTTP, streamable HTTP and stdio, and with a server built per
  request. `track` never raises into your setup code, and AgentCat holds each
  server weakly, so a server built for one request is freed with it.
- Changes to the tool list. Tools get the `session_id`, `context` and (with
  `enable_agent_tracking: true`) `agent_id` parameters, and the list gets the
  `get_more_tools` tool. AgentCat strips these parameters before your tool
  handler runs. Tools with an output schema also get the `mcp_session`
  property in `structuredContent`.
- `AgentCat::Options`, with the hooks `identify`, `resolve_session_id`,
  `event_tags`, `event_properties`, `redact_event` and
  `redact_sensitive_information`. The hooks that see a call get one frozen
  `AgentCat::ToolCall`: the tool name, the arguments, `_meta`, the HTTP
  headers, the client's name and version, and the `mcp` gem's server context.
  A hook that fails or times out costs the analytics of that event, never the
  call. A bad option value logs one warning and falls back to the default.
- `AgentCat::UserIdentity`, which the `identify` hook returns.
- `AgentCat.publish_custom_event`, which sends an `agentcat:custom` event.
- Events for the calls that the `mcp` gem rejects before a tool runs: an
  unknown tool name, a missing required argument, or arguments that fail the
  input schema.
- Each event records the MCP client's name and version, the protocol version,
  the HTTP request headers and URL, the JSON-RPC request ID, and the
  `auth_info` of the server context. Tool-call events also carry estimated
  `input_tokens` and `output_tokens`.
- Exporters for OpenTelemetry (OTLP), Datadog, Sentry and PostHog, as objects
  (`AgentCat::Exporters::Datadog.new(...)`) or as hashes with a `type`. With
  no project ID, AgentCat only forwards telemetry to your exporters.
- Event delivery on a background queue, with retries. `AgentCat.flush` sends
  queued events, and an `at_exit` hook does the same when the process ends.
- Sanitization and truncation of each event before delivery: invalid UTF-8
  becomes U+FFFD, and long strings, deep objects and large payloads are cut to
  the limits of the AgentCat API.
- Test mode: in a test environment AgentCat does nothing. `AgentCat.fake`
  records events in memory for your own tests, with assertions for Minitest
  and RSpec. `AGENTCAT_ENABLED` turns AgentCat off everywhere, or on in tests.
- `AgentCat.logger` for WARN and ERROR lines, rate-limited and free of payload
  values, and `AgentCat.debug` for a local `~/agentcat.log`.
- Internal diagnostics: an anonymized signal when setup or delivery fails.
  `disable_diagnostics: true` or `AGENTCAT_DISABLE_DIAGNOSTICS` turns them off.
- Support for the `mcp` gem 0.23.0 and later, on Ruby 3.3 and later.
  `AgentCat::PrivateMembers` lists the internals of the `mcp` gem that
  AgentCat uses. If a release of the gem removes one, AgentCat logs one error
  and turns off only the feature that needs it.

## [0.0.1] - 2026-08-23

### Added

- A placeholder that reserves the `agentcat` gem name on RubyGems. It
  contains no SDK code.

[Unreleased]: https://github.com/agentcathq/agentcat-ruby-sdk/compare/v1.0.0...HEAD
[1.0.0]: https://github.com/agentcathq/agentcat-ruby-sdk/releases/tag/v1.0.0
