# typed: true

require_relative "client"
require_relative "event_id"
require_relative "unredacted_event"
require_relative "tags"
require_relative "delivery"
require_relative "event_pipeline"

module AgentCat
  # `AgentCat.publish_custom_event`'s body - one `agentcat:custom` event for work
  # that is not a tool call: a background job, a webhook, a checkout step, anything
  # the customer wants on the same timeline as the tool calls AgentCat captures
  # automatically.
  #
  # Parity with the canonical SDKs' `publishCustomEvent`/`publish_custom_event`
  # (TS/Python) - Python's is the more defensive of the two, and is what this
  # follows field-for-field: fire-and-forget (never raises), and a single
  # unusable field costs only that field, never the whole event.
  module CustomEvent
    extend T::Sig

    sig do
      params(
        server_or_session_id: T.untyped,
        project_id: T.untyped,
        session_id: T.untyped,
        resource_name: T.untyped,
        parameters: T.untyped,
        response: T.untyped,
        message: T.untyped,
        duration: T.untyped,
        is_error: T.untyped,
        error: T.untyped,
        tags: T.untyped,
        properties: T.untyped
      ).void
    end
    def self.publish(
      server_or_session_id,
      project_id,
      session_id: nil,
      resource_name: nil,
      parameters: nil,
      response: nil,
      message: nil,
      duration: nil,
      is_error: nil,
      error: nil,
      tags: nil,
      properties: nil
    )
      session_id = wire_string("session_id", session_id)
      session_id = nil if session_id && session_id.empty?

      event = build_event(
        resource_name: resource_name, parameters: parameters, response: response,
        message: message, duration: duration, is_error: is_error, error: error,
        tags: tags, properties: properties
      )

      if server_or_session_id.is_a?(String)
        # TS: `eventData.sessionId || serverOrSessionId`, and "" goes out as null.
        publish_untracked(event, session_id || (server_or_session_id.empty? ? nil : server_or_session_id), project_id)
      else
        publish_tracked(event, server_or_session_id, session_id)
      end
    rescue => e
      Log.error("failed to publish custom event: #{e.class}; the event is lost")
      AgentCat.logger.debug { "failed to publish custom event: #{e.class}: #{e.message}" }
    end

    sig { params(event: UnredactedEvent, session_id: T.nilable(String), project_id: T.untyped).void }
    def self.publish_untracked(event, session_id, project_id)
      project = wire_string("project_id", project_id)
      if project.nil? || project.empty?
        Log.warn("publish_custom_event: project_id is required when the first argument is a session ID string; event dropped")
        return
      end

      event.session_id = session_id
      event.project_id = project
      epoch = AgentCat.event_epoch
      # No tracker, so no hooks and no per-server exporters: like TS's queue, the event
      # goes to the process-wide exporters (the first `track` that had any).
      exporters = AgentCat.process_exporters
      AgentCat.event_queue.enqueue do
        EventPipeline.normalize(event, label: "a custom event")
        next if EventPipeline.record_in_fake(event, epoch)

        Delivery.publish(AgentCat::Client, event.to_wire_hash, epoch: epoch)
        Exporters.dispatch(exporters, event)
      end
    end
    private_class_method :publish_untracked

    sig { params(event: UnredactedEvent, server: T.untyped, session_id: T.nilable(String)).void }
    def self.publish_tracked(event, server, session_id)
      tracker = AgentCat.tracker_for(server)
      unless tracker
        Log.warn(
          "publish_custom_event: first argument is neither a tracked server nor a session ID string " \
          "(got #{server.class}); event dropped. Call AgentCat.track() first, or pass a session ID."
        )
        return
      end

      options = tracker.options
      # Tracing off means nothing gets published for this server, custom events included.
      # Accepted and dropped quietly, same as the Go SDK.
      return unless options.enable_tracing

      event.session_id = session_id
      event.project_id = tracker.project_id
      epoch = AgentCat.event_epoch
      AgentCat.event_queue(queue_size: options.queue_size).enqueue do
        EventPipeline.run(event, tracker, epoch: epoch, label: "a custom event", redact_strings: false)
      end
    end
    private_class_method :publish_tracked

    sig do
      params(
        resource_name: T.untyped,
        parameters: T.untyped,
        response: T.untyped,
        message: T.untyped,
        duration: T.untyped,
        is_error: T.untyped,
        error: T.untyped,
        tags: T.untyped,
        properties: T.untyped
      ).returns(UnredactedEvent)
    end
    def self.build_event(resource_name:, parameters:, response:, message:, duration:, is_error:, error:, tags:, properties:)
      UnredactedEvent.new(
        project_id: nil,
        id: EventId.mint,
        session_id: nil,
        event_type: AgentCat::Client::CUSTOM_EVENT_TYPE,
        resource_name: wire_string("resource_name", resource_name) || "",
        parameters: wire_payload("parameters", parameters) || {},
        user_intent: wire_string("message", message),
        response: wire_payload("response", response),
        is_error: wire_bool("is_error", is_error) || false,
        error: wire_error(error),
        duration: wire_integer("duration", duration) || 0,
        timestamp: Time.now.utc.iso8601(3),
        agentcat_version: AgentCat::VERSION,
        tags: Tags.sanitize(wire_hash("tags", tags), "publish_custom_event tags"),
        properties: wire_payload("properties", properties) || {}
      )
    end
    private_class_method :build_event

    # A value the wire's strict scalar field can hold, or nil. One unusable field is
    # not worth the whole event - log and drop it, never raise.
    sig { params(field: String, value: T.untyped).returns(T.nilable(String)) }
    def self.wire_string(field, value)
      return value if value.nil? || value.is_a?(String)

      Log.warn("publish_custom_event: dropping '#{field}' - expected String, got #{value.class}")
      nil
    end
    private_class_method :wire_string

    sig { params(field: String, value: T.untyped).returns(T.nilable(Integer)) }
    def self.wire_integer(field, value)
      return value if value.nil? || value.is_a?(Integer)

      Log.warn("publish_custom_event: dropping '#{field}' - expected Integer, got #{value.class}")
      nil
    end
    private_class_method :wire_integer

    sig { params(field: String, value: T.untyped).returns(T.nilable(T::Boolean)) }
    def self.wire_bool(field, value)
      return value if value.nil? || value == true || value == false

      Log.warn("publish_custom_event: dropping '#{field}' - expected true/false, got #{value.class}")
      nil
    end
    private_class_method :wire_bool

    sig { params(field: String, value: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def self.wire_hash(field, value)
      return value if value.nil? || value.is_a?(Hash)

      Log.warn("publish_custom_event: dropping '#{field}' - expected a Hash, got #{value.class}")
      nil
    end
    private_class_method :wire_hash

    # `parameters`/`response`/`properties` hold whatever the caller wants recorded, so a
    # non-Hash is a plausible payload, not a mistake - wrapped, never dropped.
    sig { params(field: String, value: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def self.wire_payload(field, value)
      return value if value.nil? || value.is_a?(Hash)

      Log.warn("publish_custom_event: wrapping non-Hash '#{field}' (#{value.class}) as {value: ...}")
      {"value" => value}
    end
    private_class_method :wire_payload

    # `error` has a known shape consumers read `message` from, so a bare value becomes
    # one rather than a `{value: ...}` payload.
    sig { params(value: T.untyped).returns(T.nilable(T::Hash[T.untyped, T.untyped])) }
    def self.wire_error(value)
      return value if value.nil? || value.is_a?(Hash)

      {"message" => value.to_s}
    end
    private_class_method :wire_error
  end
end
