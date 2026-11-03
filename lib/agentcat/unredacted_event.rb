# typed: strict

module AgentCat
  # Everything captured about one `mcp:tools/call`, before any redaction hook runs.
  # `to_wire_hash` is what actually goes over the wire.
  class UnredactedEvent < T::Struct
    extend T::Sig

    # `project_id` is nilable: exporters forward events with no AgentCat
    # project, and only `to_wire_hash` publish to AgentCat needs a real one.
    prop :project_id, T.nilable(String)
    prop :id, String
    prop :session_id, T.nilable(String)
    prop :actor_id, T.nilable(String)
    prop :event_type, String
    prop :resource_name, String
    prop :parameters, T::Hash[String, T.untyped]
    prop :user_intent, T.nilable(String)
    prop :response, T.untyped, default: nil
    prop :is_error, T::Boolean, default: false
    prop :error, T.nilable(T::Hash[String, T.untyped]), default: nil
    prop :duration, Integer
    # Rough token cost of the call, see `TokenEstimate`. Worked out from the raw payloads
    # before redaction runs, same as the Go/TS SDKs. nil when there was nothing to count.
    prop :input_tokens, T.nilable(Integer), default: nil
    prop :output_tokens, T.nilable(Integer), default: nil
    prop :timestamp, String
    prop :server_name, T.nilable(String)
    prop :server_version, T.nilable(String)
    # Name/version of the connecting MCP client itself (e.g. "Claude Desktop" 1.2.3),
    # resolved per request: the modern `_meta` envelope, a `_meta` clientInfo key on a
    # stateless request, or the `initialize` handshake's captured clientInfo (legacy).
    # Separate from `server_name` above (that's this server) and `identify_actor_name`
    # (the human using the client). `nil` if the client didn't declare one.
    prop :client_name, T.nilable(String)
    prop :client_version, T.nilable(String)
    # Negotiated MCP protocol version for this call (e.g. "2026-07-28"). Goes out only as
    # the `agentcat_protocol_version` tag, matching the Go/TS SDKs — it is metadata about
    # the call, not a first-class event field.
    prop :protocol_version, T.nilable(String), default: nil
    # The display name, like TS's "TypeScript" and PHP's "PHP". SDK versions before
    # this one sent "ruby"; dashboards group the two spellings together.
    prop :sdk_language, String, default: "Ruby"
    prop :agentcat_version, String
    prop :identify_actor_given_id, T.nilable(String)
    prop :identify_actor_name, T.nilable(String)
    prop :identify_data, T.nilable(T::Hash[T.untyped, T.untyped])
    prop :properties, T::Hash[String, T.untyped], default: {}
    # `event_tags` hook output, already validated. Goes out as the API's first-class
    # `tags` field — `wire_tags` merges the SDK's own session/agent source tags in on
    # top, SDK wins on key collision, same order as the Go/TS SDKs' `ApplySDKTags`.
    prop :tags, T::Hash[String, String], default: {}
    # Health signals: whether the agent actually filled in `context`, and whether this
    # call came through `get_more_tools`. If context fill rate drops after a client
    # update, that needs to show up instead of quietly degrading.
    prop :context_supplied, T::Boolean, default: false
    prop :via_get_more_tools, T::Boolean, default: false
    # Why session_id/actor_id ended up what they did — minted/supplied/invalid/hook/
    # stateless/foreign for the session, identified/supplied/foreign for the actor. `nil`
    # when there's nothing to explain. Goes out as tags (`agentcat_session_id_source`,
    # `agentcat_agent_id_source`), not properties — see `wire_tags`.
    prop :session_id_source, T.nilable(String)
    prop :agent_id_source, T.nilable(String)
    # The agent_id the agent sent on this call, verbatim. Goes out as the
    # `agentcat_agent_id` tag (clamped, see `wire_tags`), same as the Go/TS SDKs — with
    # `identify` set, `actor_id` is the human, so this is the only place it shows up.
    prop :agent_id, T.nilable(String), default: nil
    # Multi round-trip (SEP-2322) round: "input_required" or "continuation", nil for an
    # ordinary call. Goes out as the `agentcat_mrtr` tag, same as the Go/TS SDKs.
    prop :mrtr, T.nilable(String), default: nil

    # SDK tags skip the customer tag validation, so the agent_id copy gets clamped here
    # the same way the Go/TS SDKs do it: CR/LF to a space, at most 200 UTF-16 code units.
    MAX_AGENT_ID_TAG_LENGTH = 200

    # message, then type, then default. Shared so every exporter agrees on the fallback
    # order instead of reimplementing it three times.
    sig { params(default: String).returns(String) }
    def error_message(default:)
      error&.dig("message") || error&.dig("type") || default
    end

    # nil fields are left off, except `session_id`: like TS (`sessionId || null`), the
    # wire always says `"session_id": null` when there is no session, and an empty
    # string counts as none. The generated model writes a nullable key only when it
    # is given one, so the key has to be here even when its value is nil.
    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_wire_hash
      wire = {
        project_id: project_id,
        id: id,
        session_id: session_id,
        actor_id: actor_id,
        event_type: event_type,
        resource_name: resource_name,
        parameters: parameters,
        user_intent: user_intent,
        response: response,
        is_error: is_error,
        error: error,
        duration: duration,
        input_tokens: input_tokens,
        output_tokens: output_tokens,
        timestamp: timestamp,
        server_name: server_name,
        server_version: server_version,
        client_name: client_name,
        client_version: client_version,
        sdk_language: sdk_language,
        agentcat_version: agentcat_version,
        identify_actor_given_id: identify_actor_given_id,
        identify_actor_name: identify_actor_name,
        identify_data: identify_data,
        tags: wire_tags,
        properties: wire_properties
      }.compact
      wire[:session_id] = (session_id.nil? || T.must(session_id).empty?) ? nil : session_id
      wire
    end

    sig { returns(T::Boolean) }
    def custom_event?
      event_type == Client::CUSTOM_EVENT_TYPE
    end

    private

    # The two health signals describe a tool call, so every tool-call event has them,
    # unlike `wire_tags`, which can legitimately end up with nothing to report. A
    # custom event is not a tool call: it sends only the customer's own properties,
    # and none at all when there are none, like TS.
    sig { returns(T.nilable(T::Hash[String, T.untyped])) }
    def wire_properties
      return (properties.empty? ? nil : properties) if custom_event?

      properties.merge(
        "agentcat_context_supplied" => context_supplied,
        "agentcat_via_get_more_tools" => via_get_more_tools
      )
    end

    # Customer tags first, then the SDK's own — SDK wins on key collision, matching
    # the Go/TS SDKs' `ApplySDKTags`.
    sig { returns(T.nilable(T::Hash[String, String])) }
    def wire_tags
      merged = tags.dup
      merged["agentcat_session_id_source"] = T.must(session_id_source) if session_id_source
      merged["agentcat_agent_id"] = Text.utf16_slice(T.must(agent_id).tr("\r\n", "  "), MAX_AGENT_ID_TAG_LENGTH) if agent_id
      merged["agentcat_mrtr"] = T.must(mrtr) if mrtr
      merged["agentcat_agent_id_source"] = T.must(agent_id_source) if agent_id_source
      merged["agentcat_protocol_version"] = T.must(protocol_version) if protocol_version
      merged.empty? ? nil : merged
    end
  end
end
