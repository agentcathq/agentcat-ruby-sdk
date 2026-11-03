# typed: true

module AgentCat
  # Single source of truth for the payload ceilings applied before an event leaves
  # the process (sanitization and truncation).
  #
  # These numbers match the Go and TypeScript SDKs exactly. Python's differ (10 KiB
  # strings, depth 5, breadth 500, no per-field ceilings) — we follow Go/TS on purpose.
  module PayloadLimits
    extend T::Sig

    # --- recursive normalization -------------------------------------------------

    # Maximum nesting depth kept before a value becomes a marker.
    MAX_DEPTH = 10
    # Depth reduction never takes `error` below this: error -> chained_errors -> item
    # -> frames -> frame keeps every frame a hash.
    MIN_ERROR_DEPTH = 5
    # Maximum number of entries kept per hash or array.
    MAX_BREADTH = 100
    # Per-string cap during normalization, in UTF-16 code units like every string
    # limit here (TS `String#length`). The "..." suffix goes on top.
    MAX_STRING_LENGTH = 32_768

    # --- total event budget ------------------------------------------------------

    # Total serialized event budget — the important one: anything over this has
    # user-controlled fields progressively reduced until it fits.
    MAX_EVENT_BYTES = 102_400

    # --- field-level string limits -------------------------------------------------
    #
    # UTF-16 code units, suffix not counted, same as the TS SDK.

    MAX_USER_INTENT_LENGTH = 2_048
    MAX_ERROR_MESSAGE_LENGTH = 2_048
    MAX_RESOURCE_NAME_LENGTH = 256
    MAX_METADATA_LENGTH = 256
    MAX_STACK_FRAMES = 50
    # How many `#cause` links to follow when capturing a chained exception.
    MAX_CHAIN_DEPTH = 10
    # Per text block inside `response[:content]`.
    MAX_CONTENT_TEXT_LENGTH = 32_768

    # --- sanitization ---------------------------------------------------------------

    # Strings at or above this size that look like base64 are treated as binary.
    BASE64_SIZE_GATE = 10_240
    # Sanitization walk depth cap (the Go SDK guards the same walk separately).
    MAX_WALK_DEPTH = 100

    # --- event_tags ---------------------------------------------------------------------
    #
    # From agentcat-api's generated docs directly (PublishEventRequest#tags), not
    # mirrored from another SDK.

    MAX_TAG_KEY_LENGTH = 32
    MAX_TAG_VALUE_LENGTH = 200
    MAX_TAGS = 50
    TAG_KEY_PATTERN = /\A[A-Za-z0-9_.:$ -]+\z/

    # --- markers -----------------------------------------------------------------------

    TRUNCATION_SUFFIX = "..."
    MAX_BREADTH_MARKER = "[MaxProperties ~]"
    OBJECT_DEPTH_MARKER = "[Object]"
    ARRAY_DEPTH_MARKER = "[Array]"
    CIRCULAR_MARKER = "[Circular ~]"
    MAX_DEPTH_EXCEEDED_MARKER = "[MAX_DEPTH_EXCEEDED]"
  end
end
