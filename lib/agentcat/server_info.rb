# typed: true

require "json"
require_relative "clock"
require_relative "client"
require_relative "redaction"
require_relative "test_mode"

module AgentCat
  # The server info heartbeat: what an agent sees on a tracked server (its title,
  # instructions and lists of tools, resources, resource templates and prompts), read
  # through the server's own list handlers and sent to AgentCat about once an hour for
  # each process, project and server name.
  #
  # A request only runs `check`, which reads and writes two in-memory values: the time of
  # the first check in this process and the time of the last attempt for each project and
  # server name. When a heartbeat is due, a short-lived thread does the list calls, the
  # redaction and the POST, and the request goes on without it. The heartbeat writes no
  # file and nothing to standard output or standard error: its log lines are debug only.
  # A process that keeps no memory (a new one, or a fork after the hour) just sends again;
  # AgentCat keeps the newest heartbeat.
  module ServerInfo
    extend T::Sig

    INTERVAL = 3600
    # A tool call starts a heartbeat only in a memory this old. A tool list request and a
    # `get_more_tools` call start one at any age.
    MIN_MEMORY_AGE = 60
    MAX_KEYS = 1000
    MAX_PAGES = 100
    LIST_TIMEOUT = 5
    BUILD_TIMEOUT = 30
    THREAD_NAME = "agentcat-server-info"
    LIST_THREAD_NAME = "agentcat-server-info-list"
    # [list request, key in `features` and in the handler's result]
    LISTS = T.let([
      ["tools/list", "tools"],
      ["resources/list", "resources"],
      ["resources/templates/list", "resourceTemplates"],
      ["prompts/list", "prompts"]
    ].freeze, T::Array[[String, String]])

    # A list that cannot be read whole.
    class ListFailed < StandardError; end

    @mutex = T.let(Mutex.new, Mutex)
    @first_check_at = T.let(nil, T.nilable(Float))
    # [project_id, server_name] => monotonic time of the last attempt
    @attempts = T.let({}, T::Hash[[String, String], Float])
    @sender = T.let(nil, T.untyped)

    class << self
      extend T::Sig

      # Anything with `post_server_info(body) -> Integer | nil`, used in place of the
      # tracked server's client. Tests set it to a recorder.
      sig { returns(T.untyped) }
      attr_accessor :sender

      # Runs on the request thread. `kind` is :tools_list, :get_more_tools or :tool_call.
      # Never raises and never waits.
      sig { params(tracker: T.untyped, kind: Symbol, server_context: T.untyped).void }
      def check(tracker, kind, server_context = nil)
        return unless due?(tracker, kind)

        start(tracker, server_context)
      rescue => e
        log("server info check failed: #{e.class}")
      end

      # Monotonic seconds; the clock of the guard.
      sig { returns(Float) }
      def now
        Clock.monotonic_now
      end

      sig { returns(Float) }
      def list_timeout
        LIST_TIMEOUT.to_f
      end

      sig { returns(Float) }
      def build_timeout
        BUILD_TIMEOUT.to_f
      end

      # Forgets the guard and the first check, as a new process would.
      sig { void }
      def reset!
        @mutex.synchronize do
          @first_check_at = nil
          @attempts = {}
        end
      end

      # Reads every page of one list through `handler` (`(params, server_context) ->
      # result`). Raises ListFailed when a cursor repeats, when the list has more than
      # MAX_PAGES pages or when a page is not a list. Each item is the JSON the server
      # would put on the wire.
      sig { params(handler: T.untyped, key: String, server_context: T.untyped).returns(T::Array[T.untyped]) }
      def read_pages(handler, key, server_context)
        items = []
        cursors = Set.new
        cursor = T.let(nil, T.untyped)
        MAX_PAGES.times do
          result = handler.call(cursor.nil? ? {} : {cursor: cursor}, server_context)
          raise ListFailed, "the #{key} result is not an object" unless result.is_a?(Hash)

          page = result[key.to_sym] || result[key]
          raise ListFailed, "the #{key} result has no list" unless page.is_a?(Array)

          items.concat(JSON.parse(JSON.generate(page)))
          cursor = result[:nextCursor] || result["nextCursor"]
          return items if cursor.nil?
          raise ListFailed, "the #{key} list repeated a cursor" unless cursors.add?(cursor)
        end
        raise ListFailed, "the #{key} list has more than #{MAX_PAGES} pages"
      end

      private

      sig { params(tracker: T.untyped, kind: Symbol).returns(T::Boolean) }
      def due?(tracker, kind)
        project_id = tracker.project_id
        return false if project_id.nil? || project_id.empty?
        return false unless tracker.options.enable_tracing
        return false unless AgentCat.active_fake.nil? && TestMode.sdk_enabled?

        key = [project_id, tracker.server_info[:name].to_s]
        current = now
        @mutex.synchronize do
          first = (@first_check_at ||= current)
          next false if kind == :tool_call && current - first < MIN_MEMORY_AGE

          last = @attempts[key]
          next false if last && current - last < INTERVAL

          @attempts = {} if @attempts.size >= MAX_KEYS
          @attempts[key] = current
          true
        end
      end

      sig { params(tracker: T.untyped, server_context: T.untyped).void }
      def start(tracker, server_context)
        sender = @sender || tracker.options.client
        epoch = AgentCat.event_epoch
        thread = Thread.new do
          Thread.current.report_on_exception = false
          run(tracker, server_context, sender, epoch)
        # Every error stays on this thread, also one that is not a StandardError: with
        # `Thread.abort_on_exception` on, an error that leaves it would reach the main thread.
        rescue Exception => e # standard:disable Lint/RescueException
          log("server info failed: #{e.class}")
        end
        thread.name = THREAD_NAME
      end

      sig { params(tracker: T.untyped, server_context: T.untyped, sender: T.untyped, epoch: Integer).void }
      def run(tracker, server_context, sender, epoch)
        return log("server info skipped: the client cannot send it") unless sender.respond_to?(:post_server_info)

        deadline = Clock.monotonic_now + build_timeout
        fields = build(tracker, server_context, deadline)
        return if fields.nil?

        fields = Redaction.apply_server_info_redaction(fields, tracker.options, deadline: deadline)
        return log("server info skipped: redact_sensitive_information raised, timed out or returned a non-String") if fields.nil?
        return log("server info skipped: it took more than #{build_timeout} seconds to build") if Clock.monotonic_now > deadline

        info = tracker.server_info
        body = {project_id: tracker.project_id, server_name: info[:name], server_version: info[:version]}.merge(fields)
        deliver(sender, body, epoch)
      end

      sig { params(tracker: T.untyped, server_context: T.untyped, deadline: Float).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
      def build(tracker, server_context, deadline)
        # Tools defined since the last request get AgentCat's parameters first, so the list
        # is the one a client gets.
        tracker.sync!
        adapter = tracker.adapter
        features = {}
        LISTS.each do |method, key|
          handler = adapter.list_handler(method)
          next if handler.nil?

          items = collect(handler, key, server_context, deadline)
          if items
            features[key] = items
          elsif key == "tools"
            return log("server info skipped: the tool list failed")
          end
        end
        return log("server info skipped: the server has no tool list") unless features.key?("tools")

        {server_title: adapter.server_title, instructions: adapter.instructions, features: features}
      end

      sig { params(handler: T.untyped, key: String, server_context: T.untyped, deadline: Float).returns(T.nilable(T::Array[T.untyped])) }
      def collect(handler, key, server_context, deadline)
        seconds = [list_timeout, deadline - Clock.monotonic_now].min
        status, value = within(seconds) { read_pages(handler, key, server_context) }
        return value if status == :ok

        reason = (status == :timeout) ? "it took more than #{seconds.round(1)} seconds" : value.class.to_s
        log("server info: the #{key} list failed (#{reason})")
        nil
      end

      # Runs the block on a thread of its own and waits at most `seconds` for it: a list
      # handler that never returns costs its list, not the heartbeat. [:ok, value],
      # [:error, exception] or [:timeout].
      sig { params(seconds: Numeric, block: T.proc.returns(T.untyped)).returns([Symbol, T.untyped]) }
      def within(seconds, &block)
        outcome = T.let([:timeout, nil], [Symbol, T.untyped])
        thread = Thread.new do
          Thread.current.report_on_exception = false
          outcome = [:ok, block.call]
        rescue Exception => e # standard:disable Lint/RescueException
          outcome = [:error, e]
        end
        thread.name = LIST_THREAD_NAME
        return outcome if thread.join([seconds, 0].max)

        thread.kill
        [:timeout, nil]
      end

      sig { params(sender: T.untyped, body: T::Hash[Symbol, T.untyped], epoch: Integer).void }
      def deliver(sender, body, epoch)
        status = post(sender, body, epoch)
        if status == 413
          body = body.merge(features: without_schemas(body[:features]))
          status = post(sender, body, epoch)
        end
        return if status == :stale

        if status.is_a?(Integer) && status.between?(200, 299)
          log("server info sent: #{body[:features]["tools"].size} tools, #{byte_size(body)} bytes")
        else
          log("server info not accepted: #{status.nil? ? "no answer" : "HTTP #{status}"}")
        end
      end

      # The answer's status, nil for no answer, :stale after `AgentCat.reset!`.
      sig { params(sender: T.untyped, body: T::Hash[Symbol, T.untyped], epoch: Integer).returns(T.untyped) }
      def post(sender, body, epoch)
        return :stale if epoch != AgentCat.event_epoch

        sender.post_server_info(body)
      rescue => e
        log("server info send failed: #{e.class}")
        nil
      end

      # Each tool keeps its name, title and description, for a body under the size limit.
      sig { params(features: T::Hash[String, T.untyped]).returns(T::Hash[String, T.untyped]) }
      def without_schemas(features)
        features.merge("tools" => features.fetch("tools").map { |tool| tool.is_a?(Hash) ? tool.except("inputSchema", "outputSchema") : tool })
      end

      sig { params(body: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
      def byte_size(body)
        JSON.generate(body).bytesize
      rescue
        "unknown"
      end

      # Debug only: the default logger writes warnings to standard error, which a stdio
      # server must keep clean. Returns nil, so a step can `return log(...)`.
      sig { params(line: String).returns(NilClass) }
      def log(line)
        AgentCat.logger.debug(line)
        nil
      rescue
        nil
      end
    end
  end
end
