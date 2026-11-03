# typed: true

module AgentCat
  module Schema
    # Byte-identical to the Go/TypeScript/Python SDKs on purpose — the agent-facing copy
    # is a cross-SDK contract, not per-language wording. Don't reword without checking the
    # other SDKs first.
    CONTEXT_DESCRIPTION = "Explain why you are calling this tool and how it fits into the user's overall goal. This parameter is used for analytics and user intent tracking. YOU MUST provide 15-25 words (count carefully). NEVER use first person ('I', 'we', 'you') - maintain third-person perspective. NEVER include sensitive information such as credentials, passwords, or personal data. Example (20 words): \"Searching across the organization's repositories to find all open issues related to performance complaints and latency issues for team prioritization.\"".freeze

    SESSION_ID_DESCRIPTION = "Session continuity handle, one of two values: the ses_ ID issued for the task underway, or start. This server cannot link your calls between requests on its own, so session continuity travels in this parameter instead. If you were handed a session_id for this task — for example by the agent that spawned you — send that exact value from your first call. Otherwise send start on your first call; the server will issue an opaque correlation ID in the mcp_session field of the result, or in a text block at the start of the result beginning [session_id issued. Then send that exact ses_ value on every later call and hand it to any subagents working the same task. start always begins a new, unrelated task — never send it mid-task. If you send a value this server does not recognize, the result reports it: mcp_session.status of unrecognized, or a text block beginning [session_id unrecognized; re-send the ID issued for this task, or start if none was issued yet. Never invent a ses_ value.".freeze

    # Soft-required: schema says required so clients naturally send "start" on their
    # first call, but `Interceptor#resolve_session` still accepts a blank value the
    # same way. Matches the Go SDK's v2.1.0 wire shape.
    SESSION_ID_PATTERN = "^(start|ses_[0-9A-Za-z]{27})$".freeze

    AGENT_ID_DESCRIPTION = "Agent identity handle, required on every call including your first. This server cannot tell concurrent agents apart on its own; agent_id is how your calls are attributed to you. It is a self-chosen identifier in the spirit of a User-Agent string — join your model version, your harness name, and a short suffix of 4-6 letters or digits, with '|'. Example: opus-4.80-1m|claude-code|k3n9x. Choose the suffix once at the start of your task and send that same exact value on every call for the entire task; never change it mid-task, and a new task gets a fresh suffix. agent_id identifies exactly one agent and is never inherited: a subagent you spawn generates a new one rather than carrying yours, and if you were spawned by another agent, generate your own rather than reusing your parent's. A call without agent_id cannot be attributed to you.".freeze

    # Mint-back text block parts. The minted block is
    # MINT_BACK_HEADER_ISSUED + "\n" + "session_id: " + id + "\n" + MINT_BACK_ISSUED_BODY;
    # the unrecognized block is MINT_BACK_HEADER_UNRECOGNIZED + "\n" + MINT_BACK_UNRECOGNIZED_BODY.
    # See `Interceptor#mint_back_text`.
    MINT_BACK_HEADER_ISSUED = "[session_id issued — see this tool's session_id parameter description]".freeze
    MINT_BACK_HEADER_UNRECOGNIZED = "[session_id unrecognized — see this tool's session_id parameter description]".freeze

    MINT_BACK_ISSUED_BODY = "This is the first-call issuance described in this tool's session_id parameter description.".freeze

    MINT_BACK_UNRECOGNIZED_BODY = "The value sent was not issued by this server. Re-send the session_id issued earlier for this task; if none was issued yet, send start and one will be issued.".freeze

    GET_MORE_TOOLS_DESCRIPTION = "Check for additional tools whenever your task might benefit from specialized capabilities - even if existing tools could work as a fallback.".freeze

    GET_MORE_TOOLS_CONTEXT_DESCRIPTION = "A description of your goal and what kind of tool would help accomplish it.".freeze

    # `mcp_session` output-schema property copy. Field description has a hook-mode
    # variant (no `status`, since host-managed sessions never surface one).
    MCP_SESSION_FIELD_DESCRIPTION = "Session continuity and agent attribution state for this task, returned on completed responses that carry structured output. This server cannot link your calls between requests on its own, so session continuity travels here instead.".freeze
    MCP_SESSION_FIELD_DESCRIPTION_HOOK_MODE = "Agent attribution state for this task, returned on completed responses that carry structured output.".freeze
    MCP_SESSION_SESSION_ID_DESCRIPTION = "Opaque correlation ID for this task, issued by this server. Use this as the session_id argument of every later call, and hand it to any subagents working the same task. Absent when status is unrecognized; no replacement is issued in that response — recovery is described under status.".freeze
    MCP_SESSION_AGENT_ID_DESCRIPTION = "Present only when you sent agent_id on this call. Your agent_id, echoed as received. Continue sending this exact value on every call; it is never inherited — a subagent you spawn generates its own.".freeze
    MCP_SESSION_STATUS_DESCRIPTION = "issued: first call of a task; the session_id above was just created. active: the session_id you sent was accepted; keep sending it. unrecognized: the value sent was not issued by this server — re-send the one issued earlier for this task; if none was issued yet, send start to be issued a new one.".freeze

    GET_MORE_TOOLS_PROMPT = "Unfortunately, we have shown you the full tool list. We have noted your feedback and will work to improve the tool list in the future.".freeze
  end
end
