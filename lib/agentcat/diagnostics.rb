# typed: true

require "digest"
require "etc"
require "json"
require "logger"
require "socket"

require_relative "version"
require_relative "http_post"
require_relative "test_mode"

module AgentCat
  class << self
    extend T::Sig

    # Defaults to WARN on $stderr — best-effort failures (publishing, bad config)
    # shouldn't show up in tool results, but they shouldn't vanish either.
    sig { params(logger: Logger).void }
    attr_writer :logger

    sig { returns(Logger) }
    def logger
      @logger ||= Logger.new($stderr, level: Logger::WARN, progname: "agentcat")
    end

    # When true, also appends to ~/agentcat.log (never $stderr — stdio transports
    # need that clean). Independent of the remote beacon's on/off switch.
    sig { returns(T::Boolean) }
    def debug?
      !!@debug
    end

    sig { params(debug: T::Boolean).void }
    attr_writer :debug
  end

  # Anonymized signal sent back to AgentCat when setup or runtime errors happen.
  # Just operational metadata — project id (or an anonymous install id), SDK/MCP/
  # runtime versions, host shape. Never tool calls, responses, or anything about
  # your users.
  #
  # Ships as an OTLP/HTTP log record to https://otel.agentcat.com/v1/logs (override
  # with AGENTCAT_DIAGNOSTICS_ENDPOINT / AGENTCAT_DIAGNOSTICS_TOKEN). On by default —
  # turn it off with Options#disable_diagnostics or AGENTCAT_DISABLE_DIAGNOSTICS
  # (false/0/no/off forces it back on). The unprefixed DISABLE_DIAGNOSTICS (the TS
  # name) can only turn it off; the unprefixed DIAGNOSTICS_ENDPOINT/DIAGNOSTICS_TOKEN
  # are never read, so an app's own variables never reach AgentCat. Test
  # processes disable themselves unless forced. ~/agentcat.log doesn't care about any
  # of this.
  module Diagnostics
    DEFAULT_ENDPOINT = "https://otel.agentcat.com"
    DEFAULT_TOKEN = "dgk_sdk_diag_3f9a2c7e1b8d4065af2e9c1d7b6a4f80"
    SCOPE_NAME = "agentcat-diagnostics"
    LOGS_PATH = "/v1/logs"
    MAX_BUFFER = 1000
    FLUSH_DELAY = 2
    # A blocked collector costs a flush (and so `AgentCat.flush` / at_exit) at
    # most about a second.
    CONNECT_TIMEOUT = 0.25
    TOTAL_TIMEOUT = 1.0
    LOCAL_LOG_NAME = "agentcat.log"
    # lib/agentcat/../.. - the installed gem's directory.
    GEM_ROOT = T.let(
      begin
        File.realpath(File.expand_path("../..", __dir__))
      rescue SystemCallError
        File.expand_path("../..", __dir__)
      end,
      String
    )

    SEVERITY = T.let(
      {
        info: [9, "INFO"],
        warn: [13, "WARN"],
        error: [17, "ERROR"]
      }.freeze,
      T::Hash[Symbol, T::Array[T.untyped]]
    )

    extend T::Sig

    @mutex = T.let(Mutex.new, Mutex)
    @initialized = T.let(false, T::Boolean)
    @enabled = T.let(false, T::Boolean)
    @buffer = T.let([], T::Array[T::Hash[String, T.untyped]])
    @flush_pending = T.let(false, T::Boolean)
    @static_attrs = T.let([], T::Array[T::Hash[String, T.untyped]])
    @record_attrs = T.let([], T::Array[T::Hash[String, T.untyped]])

    class << self
      extend T::Sig

      # Test seam: (url, headers, body) -> [status, body].
      sig { returns(T.untyped) }
      attr_accessor :http_post

      # Idempotent — only the first call per process does anything. Never raises.
      sig { params(project_id: T.nilable(String), integration: String, disabled: T::Boolean).void }
      def init(project_id:, integration:, disabled:)
        @mutex.synchronize do
          return if @initialized

          @initialized = true
          @static_attrs = build_static_attributes(project_id, integration)
          @record_attrs = build_record_attributes
          @enabled = compute_enabled?(disabled)
        end
      rescue => e
        AgentCat.logger.debug { "diagnostics init failed: #{e.class}: #{e.message}" }
      end

      # Buffers a message for the next batched send; also writes to agentcat.log
      # when debug? is on. Never raises, never blocks.
      sig { params(level: Symbol, message: String).void }
      def record(level, message)
        file_log(level, message) if AgentCat.debug?
        return unless @enabled
        return if level == :debug

        flush_already_pending = schedule_record(record: build_record(level, message))
        spawn_flush unless flush_already_pending
      rescue => e
        AgentCat.logger.debug { "diagnostics record failed: #{e.class}: #{e.message}" }
      end

      # Best-effort send of whatever's buffered, bounded by TOTAL_TIMEOUT. AgentCat.flush
      # (and so the at_exit hook) calls this too, so a record never waits for the
      # FLUSH_DELAY batch timer at shutdown.
      sig { void }
      def flush
        records = @mutex.synchronize do
          pending = @buffer
          @buffer = []
          pending
        end
        return if records.empty?

        post(build_payload(records))
      rescue => e
        AgentCat.logger.debug { "diagnostics flush failed: #{e.class}: #{e.message}" }
      end

      sig { returns(T::Boolean) }
      def enabled?
        @enabled
      end

      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def static_attributes
        @static_attrs
      end

      # Node `os.platform()` names for `Etc.uname[:sysname]`: `win32` for Windows,
      # else the name in lower case (`linux`, `darwin`, `freebsd`, `sunos`).
      sig { params(sysname: String).returns(String) }
      def os_type(sysname)
        name = sysname.downcase
        name.start_with?("windows", "mingw", "msys", "cygwin") ? "win32" : name
      end

      # Node `os.arch()` names for x64 and arm64 (any case); any other machine name as is.
      sig { params(machine: String).returns(String) }
      def arch(machine)
        case machine.downcase
        when "x86_64", "amd64", "x64" then "x64"
        when "aarch64", "arm64" then "arm64"
        else machine
        end
      end

      sig { returns(Integer) }
      def buffer_size
        @mutex.synchronize { @buffer.size }
      end

      # Test helper, called from AgentCat.reset!.
      sig { void }
      def reset!
        @mutex.synchronize do
          @initialized = false
          @enabled = false
          @buffer = []
          @flush_pending = false
          @static_attrs = []
          @record_attrs = []
        end
      end

      private

      # The option, then AGENTCAT_DISABLE_DIAGNOSTICS, then the test environment. The
      # unprefixed DISABLE_DIAGNOSTICS can only turn diagnostics off, also over a false
      # AGENTCAT_DISABLE_DIAGNOSTICS: a privacy opt-out fails closed.
      sig { params(disabled: T::Boolean).returns(T::Boolean) }
      def compute_enabled?(disabled)
        return false if disabled

        flag = (env_flag("DISABLE_DIAGNOSTICS") == :disabled) ? :disabled : env_flag("AGENTCAT_DISABLE_DIAGNOSTICS")
        return false if flag == :disabled
        return true if flag == :force_enabled

        !test_environment?
      end

      # Mirrors TS `envDiagnosticsFlag`: blank is "unset", false/0/no/off (trimmed, any
      # case) forces it back on, anything else turns it off.
      sig { params(name: String).returns(Symbol) }
      def env_flag(name)
        case ENV[name].to_s.strip.downcase
        when ""
          :unset
        when "false", "0", "no", "off"
          :force_enabled
        else
          :disabled
        end
      end

      # Off in the same test environments as test mode (TestMode). Not the
      # AGENTCAT_ENABLED answer: forcing the SDK on in tests keeps diagnostics off
      # unless AGENTCAT_DISABLE_DIAGNOSTICS=false forces them on too.
      sig { returns(T::Boolean) }
      def test_environment?
        TestMode.test_environment?
      end

      sig { returns(String) }
      def endpoint
        base = ENV["AGENTCAT_DIAGNOSTICS_ENDPOINT"].to_s.strip
        base = DEFAULT_ENDPOINT if base.empty?
        base = base.chomp("/")
        base.end_with?(LOGS_PATH) ? base : "#{base}#{LOGS_PATH}"
      end

      sig { returns(String) }
      def token
        value = ENV["AGENTCAT_DIAGNOSTICS_TOKEN"].to_s.strip
        value.empty? ? DEFAULT_TOKEN : value
      end

      # Stable per-install id for setups with no project id to attribute telemetry to
      # instead (TS uses `hostname|import.meta.url`): hostname + "|file://" + the
      # gem root, symlinks resolved, hashed. Not the cwd or $0, so every script of one
      # install shares it. The hostname is hashed, never sent.
      sig { returns(String) }
      def install_id
        Digest::SHA256.hexdigest("#{Socket.gethostname}|file://#{GEM_ROOT}").slice(0, 16) || "0" * 16
      rescue => e
        AgentCat.logger.debug { "diagnostics install_id failed: #{e.class}: #{e.message}" }
        "0" * 16
      end

      sig { returns(T.nilable(String)) }
      def mcp_version
        return nil unless defined?(MCP)
        return nil unless MCP.respond_to?(:const_get) && MCP.const_defined?(:VERSION)

        MCP::VERSION.to_s
      end

      sig do
        params(record: T::Hash[String, T.untyped]).returns(T::Boolean)
      end
      def schedule_record(record:)
        @mutex.synchronize do
          @buffer.shift while @buffer.size >= MAX_BUFFER
          @buffer << record
          flush_pending = @flush_pending
          @flush_pending = true
          flush_pending
        end
      end

      sig do
        params(
          project_id: T.nilable(String),
          integration: String
        ).returns(T::Array[T::Hash[String, T.untyped]])
      end
      def build_static_attributes(project_id, integration)
        attrs = []
        if project_id.nil? || project_id.empty?
          add_attr!(attrs, "agentcat.install_id", install_id)
        else
          add_attr!(attrs, "agentcat.project_id", project_id)
        end

        add_attr!(attrs, "agentcat.sdk.language", "ruby")
        add_attr!(attrs, "agentcat.sdk.version", AgentCat::VERSION)
        add_attr!(attrs, "agentcat.mcp_sdk.version", mcp_version)
        add_attr!(attrs, "agentcat.integration", integration)

        add_attr!(attrs, "process.runtime.name", "ruby")
        add_attr!(attrs, "process.runtime.version", RUBY_VERSION)
        add_attr!(attrs, "process.pid", Process.pid)

        # Node vocabulary, and no host.cpu.count.
        uname = self.uname
        sysname = uname[:sysname]
        machine = uname[:machine]
        add_attr!(attrs, "os.type", sysname && os_type(sysname))
        add_attr!(attrs, "os.version", uname[:release])
        add_attr!(attrs, "host.arch", machine && arch(machine))

        add_attr!(attrs, "deployment.environment", deployment_environment)
        attrs
      end

      sig { returns(T::Hash[Symbol, T.nilable(String)]) }
      def uname
        Etc.uname
      rescue => e
        AgentCat.logger.debug { "diagnostics uname failed: #{e.class}: #{e.message}" }
        {}
      end

      # The Rack/Rails names, like NODE_ENV in TS and APP_ENV in PHP. Blank counts as unset.
      sig { returns(T.nilable(String)) }
      def deployment_environment
        %w[RAILS_ENV RACK_ENV].each do |name|
          value = ENV[name].to_s.strip
          return value unless value.empty?
        end
        nil
      end

      sig { returns(T::Array[T::Hash[String, T.untyped]]) }
      def build_record_attributes
        attrs = []
        add_attr!(attrs, "agentcat.sdk.version", AgentCat::VERSION)
        add_attr!(attrs, "agentcat.mcp_sdk.version", mcp_version)
        add_attr!(attrs, "process.runtime.version", RUBY_VERSION)
        attrs
      end

      sig { params(level: Symbol, message: String).returns(T::Hash[String, T.untyped]) }
      def build_record(level, message)
        severity, text = SEVERITY.fetch(level, SEVERITY[:info])
        {
          "timeUnixNano" => (Time.now.to_r * 1_000_000_000).to_i.to_s,
          "severityNumber" => severity,
          "severityText" => text,
          "body" => {"stringValue" => message},
          "attributes" => @record_attrs
        }
      end

      sig { params(records: T::Array[T::Hash[T.untyped, T.untyped]]).returns(T::Hash[String, T.untyped]) }
      def build_payload(records)
        {
          "resourceLogs" => [
            {
              "resource" => {"attributes" => @static_attrs},
              "scopeLogs" => [
                {
                  "scope" => {"name" => SCOPE_NAME, "version" => AgentCat::VERSION},
                  "logRecords" => records
                }
              ]
            }
          ]
        }
      end

      sig { void }
      def spawn_flush
        Thread.new do
          sleep(FLUSH_DELAY)
          @mutex.synchronize { @flush_pending = false }
          flush
        end
      rescue ThreadError
        nil
      end

      sig { params(payload: T::Hash[String, T.untyped]).void }
      def post(payload)
        sender = http_post || default_http_post
        sender.call(endpoint, build_headers, payload.to_json)
      end

      sig { returns(T::Hash[String, String]) }
      def build_headers
        {
          "Content-Type" => "application/json",
          "Authorization" => "Bearer #{token}",
          "User-Agent" => "agentcat-ruby/#{AgentCat::VERSION}"
        }
      end

      # Doesn't raise on non-2xx.
      sig do
        returns(
          T.proc.params(
            url: String,
            headers: T::Hash[String, String],
            body: String
          ).returns([Integer, String])
        )
      end
      def default_http_post
        lambda do |url, headers, body|
          HttpPost.call(url, headers, body, open_timeout: CONNECT_TIMEOUT, read_timeout: TOTAL_TIMEOUT, deadline: TOTAL_TIMEOUT)
        end
      end

      sig { params(level: Symbol, message: String).void }
      def file_log(level, message)
        path = File.join(Dir.home, LOCAL_LOG_NAME)
        File.open(path, "a") do |file|
          file.puts "[agentcat] #{Time.now.utc.iso8601} #{level.to_s.upcase}: #{message}"
        end
      rescue => e
        AgentCat.logger.debug { "diagnostics file log failed: #{e.class}: #{e.message}" }
      end

      sig do
        params(
          attrs: T::Array[T::Hash[String, T.untyped]],
          key: String,
          value: T.untyped
        ).void
      end
      def add_attr!(attrs, key, value)
        return if value.nil?
        return if value.to_s.empty?

        attrs << {"key" => key, "value" => {"stringValue" => value.to_s}}
      end
    end
  end
end
