# typed: true

require "sorbet-runtime"

require_relative "agentcat/version"
require_relative "agentcat/clock"
require_relative "agentcat/log"
require_relative "agentcat/private_members"
require_relative "agentcat/http_post"
require_relative "agentcat/test_mode"
require_relative "agentcat/diagnostics"
require_relative "agentcat/schema/prompts"
require_relative "agentcat/options"
require_relative "agentcat/hooks"
require_relative "agentcat/session_manager"
require_relative "agentcat/event_id"
require_relative "agentcat/user_identity"
require_relative "agentcat/request_context"
require_relative "agentcat/tool_call"
require_relative "agentcat/client"
require_relative "agentcat/tool_handle"
require_relative "agentcat/adapters/base"
require_relative "agentcat/adapters/official"
require_relative "agentcat/text"
require_relative "agentcat/unredacted_event"
require_relative "agentcat/token_estimate"
require_relative "agentcat/payload_limits"
require_relative "agentcat/tags"
require_relative "agentcat/sanitization"
require_relative "agentcat/truncation"
require_relative "agentcat/error_capture"
require_relative "agentcat/redaction"
require_relative "agentcat/event_queue"
require_relative "agentcat/delivery"
require_relative "agentcat/exporters"
require_relative "agentcat/event_pipeline"
require_relative "agentcat/fork_safety"
require_relative "agentcat/custom_event"
require_relative "agentcat/interceptor"
require_relative "agentcat/tracker"

module AgentCat
  # `AgentCat.fake` and its assertions. Loaded on first use, not with the SDK.
  autoload :Testing, File.expand_path("agentcat/testing", __dir__)

  PROJECT_ID_PATTERN = /\Aproj_[A-Za-z0-9]{27}\z/
  ADAPTERS = [Adapters::Official].freeze
  # Like TS's 5 s graceful shutdown.
  AT_EXIT_FLUSH_TIMEOUT = 5

  # Server => Tracker, both held weakly, so a server built per request (the README's
  # stateless pattern) is collected with its tracker once the request is done. The
  # server keeps its own tracker alive: the dispatch wrapper and the tool handles that
  # `Tracker#install!` puts on it reference the tracker. WeakMap compares keys by
  # identity on every Ruby we support. Not `ObjectSpace::WeakKeyMap` (3.3+): it holds
  # values strongly and the tracker references its server (through the adapter), so no
  # server would ever be collected.
  @trackers = ObjectSpace::WeakMap.new
  @mutex = Mutex.new
  @event_queue = T.let(nil, T.nilable(EventQueue))
  @event_queue_mutex = Mutex.new
  @event_queue_epoch = T.let(0, Integer)
  @at_exit_registered = false
  # The first tracked server's non-empty `Options#exporters`. Untracked custom events
  # (no tracker, so no options of their own) go here, like TS's process-wide
  # telemetry manager, which is also first-wins.
  @process_exporters = T.let([], T::Array[T.untyped])
  # `AgentCat.fake`'s recorder while a test uses one.
  @fake = T.let(nil, T.untyped)
  # A `track` ran while AgentCat was off (test mode or AGENTCAT_ENABLED=false).
  @skipped_track = T.let(false, T::Boolean)
  # Malformed project IDs already warned about, so a per-request `track` logs one line.
  @warned_project_ids = T.let({}, T::Hash[String, TrueClass])

  class << self
    extend T::Sig

    # Instruments `server` so that every tool call is attributed to a session and reported to AgentCat.
    #
    # Returns the server. Tracking is idempotent per server instance, and a server no adapter
    # recognises is returned untouched.
    #
    # `project_id` nil, empty or blank means telemetry only: events go to `Options#exporters`
    # and not to AgentCat (TS parity; `AGENTCAT_PROJECT_ID` is not read). A project ID that
    # does not look like `proj_` plus 27 letters or digits logs one warning and is sent as
    # given, like the TypeScript and PHP SDKs: the AgentCat API decides.
    #
    # `AGENTCAT_ENABLED` turns AgentCat off everywhere with `false`, `0`, `no` or `off`, and
    # on everywhere with `true`, `1`, `yes` or `on`. Otherwise AgentCat does nothing in test
    # environments (Minitest or RSpec loaded, or `RAILS_ENV`/`RACK_ENV`/`APP_ENV` set to
    # `test` or `testing`) unless the test called `AgentCat.fake` first. "Nothing" means the
    # server comes back untouched: no instrumentation, no delivery, no diagnostics.
    sig { params(server: T.untyped, project_id: T.nilable(String), options: T.nilable(AgentCat::Options)).returns(T.untyped) }
    def track(server, project_id = nil, options = nil)
      unless TestMode.sdk_enabled?
        @mutex.synchronize { @skipped_track = true }
        return server
      end

      project_id = normalize_project_id(project_id)
      options ||= Options.new
      # A fake sends nothing, diagnostics included.
      unless active_fake
        Diagnostics.init(
          project_id: project_id,
          integration: integration_name(options),
          disabled: options.disable_diagnostics
        )
        Diagnostics.record(:info, "AgentCat setup started | project #{project_display(project_id)}")
        # Before anything can fail: a process whose `track` fails and then exits still
        # sends that diagnostics record from the at_exit flush.
        register_at_exit_flush!
      end

      begin
        warn_if_malformed_project_id(project_id)
        %i[identify resolve_session_id event_tags event_properties].each do |name|
          Hooks.warn_if_two_arguments(options.public_send(name), name.to_s)
        end

        adapter_class = detect_adapter(server)
        unless adapter_class
          Diagnostics.record(:warn, "AgentCat setup skipped | no adapter for #{server.class}")
          return server
        end

        # Once per process: every `mcp` gem internal AgentCat uses is there, or its
        # feature is off (one ERROR line each).
        PrivateMembers.check! if adapter_class == Adapters::Official

        # Process-wide: captures incoming HTTP headers for `parameters.extra`. A
        # no-op for stdio and for a process where the HTTP transport isn't loaded
        # (yet); idempotent, so a second `track` doesn't re-patch.
        RequestContext.install!

        @mutex.synchronize do
          return server if @trackers.key?(server)

          # Built first: if building it raises, the first-wins process-wide settings
          # below stay free for a `track` that works.
          tracker = Tracker.new(adapter: adapter_class.new(server), project_id: project_id, options: options)
          configure_default_client(options)
          @process_exporters = options.exporters.dup.freeze if @process_exporters.empty? && !options.exporters.empty?
          begin
            tracker.install!
          rescue => e
            Log.error("AgentCat failed to instrument the server, so some of its calls are not tracked: #{e.class}: #{e.message}")
            Diagnostics.record(:warn, "AgentCat failed to instrument server | #{e.class}: #{e.message}")
          end
          @trackers[server] = tracker
        end

        server
      rescue => e
        # `track` never raises into setup code. A wrong argument type still
        # fails fast in the sig above, before this method body runs.
        Log.error("AgentCat setup failed, the server is not tracked: #{e.class}: #{e.message}")
        Diagnostics.record(:error, "AgentCat setup failed | #{e.class}: #{e.message}")
        server
      end
    end

    sig { params(server: T.untyped).returns(T.nilable(AgentCat::Tracker)) }
    def tracker_for(server)
      @mutex.synchronize { @trackers[server] }
    end
    alias_method :_tracking_data, :tracker_for

    sig { params(server: T.untyped).returns(T::Boolean) }
    def tracked?(server)
      !tracker_for(server).nil?
    end

    # Forgets every tracked server. Instrumentation already installed on a server stays in place.
    # The event queue is torn down and rebuilt lazily, so nothing queued (or retrying) from before
    # the reset can publish into whatever follows it.
    #
    # Also removes `AgentCat.fake`'s recorder: call it in your test's teardown.
    sig { void }
    def reset!
      Diagnostics.reset!
      Log.reset!
      PrivateMembers.reset!
      @event_queue_mutex.synchronize do
        @event_queue_epoch += 1
        @event_queue&.shutdown
        @event_queue = nil
      end
      @mutex.synchronize do
        @trackers = ObjectSpace::WeakMap.new
        @process_exporters = []
        @fake = nil
        @skipped_track = false
        @warned_project_ids = {}
      end
    end

    # Starts recording for your test suite and returns the recorder to assert on. While
    # it is active, AgentCat instruments servers even in a test environment (and even
    # with AGENTCAT_ENABLED=false), but every event goes to the fake instead of AgentCat,
    # the exporters or diagnostics. Call it before `track`: in a test environment, a
    # server tracked before `fake` is not tracked at all. A second call replaces the
    # recorder. `AgentCat.reset!` (in your teardown) removes it.
    #
    #   fake = AgentCat.fake
    #   AgentCat.track(server, "proj_...")
    #   # ... call a tool ...
    #   fake.assert_tracked("my_tool")
    sig { returns(AgentCat::Testing::Fake) }
    def fake
      recorder = Testing::Fake.new
      @mutex.synchronize { @fake = recorder }
      recorder
    end

    # The active `fake`, or nil. Internal: the event pipeline asks it.
    sig { returns(T.nilable(AgentCat::Testing::Fake)) }
    def active_fake
      @fake
    end

    # Whether a `track` ran while AgentCat was off, for the fake's failure messages.
    sig { returns(T::Boolean) }
    def skipped_track?
      @skipped_track
    end

    # See `@process_exporters` above.
    sig { returns(T::Array[T.untyped]) }
    def process_exporters
      @mutex.synchronize { @process_exporters }
    end

    # Monotonic counter bumped by `reset!`. `Delivery` compares against it between publish
    # attempts so an event enqueued before a reset isn't delivered into a stale process state.
    sig { returns(Integer) }
    def event_epoch
      @event_queue_mutex.synchronize { @event_queue_epoch }
    end

    sig { params(server: T.untyped).returns(T.nilable(T.class_of(AgentCat::Adapters::Base))) }
    def detect_adapter(server)
      ADAPTERS.find { |adapter| adapter.supports?(server) }
    end

    # Lazy, process-wide. Created on first use rather than at `track()` time, so a
    # process that never publishes anything never spawns a worker thread. `queue_size`
    # only takes effect on that first creation, same as the client timeout.
    sig { params(queue_size: T.nilable(Integer)).returns(EventQueue) }
    def event_queue(queue_size: nil)
      @event_queue_mutex.synchronize do
        @event_queue ||= begin
          ForkSafety.install!
          register_at_exit_flush!
          EventQueue.new(max_size: queue_size || EventQueue::DEFAULT_MAX_SIZE)
        end
      end
    end

    # For the `Process._fork` hook — not meant to be called directly.
    sig { void }
    def reset_event_queue_after_fork!
      @event_queue&.reset_after_fork!
    end

    # Waits for queued events to publish, then sends AgentCat's pending diagnostics
    # records (at most about 1 s more, see Diagnostics::TOTAL_TIMEOUT). Returns whether
    # the event queue drained in time. `at_exit` calls this too (with a 5 s budget), but
    # that's best-effort only — no SIGKILL, no guaranteed ordering against Puma's
    # shutdown — so call it explicitly on shutdown if you're in a container or anything
    # short-lived.
    sig { params(timeout: Numeric).returns(T::Boolean) }
    def flush(timeout: 5)
      drained = @event_queue.nil? || @event_queue.flush(timeout: timeout)
      # After the events: a publish that gave up records a diagnostics line.
      Diagnostics.flush
      drained
    end

    # Publishes one `agentcat:custom` event for work that is not a tool call - a
    # background job, a webhook, a checkout step, anything you want on the same
    # timeline as the tool calls AgentCat captures automatically.
    #
    # `server_or_session_id` is either a server already passed to `track()`, or a
    # session ID string used verbatim (never validated, trimmed, or derived - this is
    # a deliberate call, not an agent's guess). `session_id:` takes precedence over
    # a string first argument, and attributes the event to a task; without one, a
    # tracked server publishes without a session (handles are per-request, so a
    # tracked server has no ambient one to fall back on).
    #
    # `project_id` is used as given in the session-ID-string form. In the tracked-
    # server form it's ignored - the project captured at `track()` time wins, so a
    # telemetry-only server still publishes.
    #
    # Does nothing where `track` does nothing (see `AGENTCAT_ENABLED` there); with
    # `AgentCat.fake`, the event goes to the fake.
    #
    # Fire-and-forget: never raises. A mistyped `resource_name`/`message`/`duration`/
    # `is_error`/`tags` costs that field, not the event; a non-Hash `parameters`/
    # `response`/`properties` is wrapped as `{value: ...}` and kept, since the wire
    # field holds an object and the payload is yours to keep.
    #
    # Every customer-data param below is `T.untyped`, not the type it's documented to
    # want: a `sig` must not be what enforces this (same rule as hook return values,
    # see Options' typing note) - a mistyped field has to reach CustomEvent's own
    # wire_* coercion to be downgraded gracefully, not raise here first.
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
    def publish_custom_event(
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
      return unless TestMode.sdk_enabled?

      CustomEvent.publish(
        server_or_session_id, project_id,
        session_id: session_id, resource_name: resource_name, parameters: parameters,
        response: response, message: message, duration: duration, is_error: is_error,
        error: error, tags: tags, properties: properties
      )
    end

    private

    sig { void }
    def register_at_exit_flush!
      return if @at_exit_registered

      @at_exit_registered = true
      at_exit { flush(timeout: AT_EXIT_FLUSH_TIMEOUT) }
    end

    # First `track` wins, like the event queue's size.
    sig { params(options: AgentCat::Options).void }
    def configure_default_client(options)
      return unless options.default_client?

      Client.configure_timeout(options.request_timeout)
      base_url = options.api_base_url
      Client.configure_base_url(base_url) if base_url
    end

    # nil, "" and whitespace-only all mean telemetry only.
    sig { params(project_id: T.nilable(String)).returns(T.nilable(String)) }
    def normalize_project_id(project_id)
      return nil if project_id.nil? || project_id.strip.empty?

      project_id
    end

    sig { params(project_id: T.nilable(String)).void }
    def warn_if_malformed_project_id(project_id)
      return if project_id.nil? || project_id.match?(PROJECT_ID_PATTERN)
      first_time = @mutex.synchronize { @warned_project_ids.store(project_id, true) unless @warned_project_ids.key?(project_id) }
      return unless first_time

      message = "project_id #{project_id.inspect} does not match proj_ followed by 27 letters or digits; " \
        "events are sent with it as given, and the AgentCat API can reject them"
      logger.warn(message)
      Diagnostics.record(:warn, "AgentCat setup warning | #{message}")
    end

    sig { params(_options: AgentCat::Options).returns(String) }
    def integration_name(_options)
      "ruby"
    end

    sig { params(project_id: T.nilable(String)).returns(String) }
    def project_display(project_id)
      project_id.to_s.empty? ? "(telemetry-only)" : project_id.to_s
    end
  end
end
