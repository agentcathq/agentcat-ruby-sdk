require_relative "test_helper"
require "json"
require "tmpdir"
require "fileutils"
require "digest"
require "etc"
require "socket"
require "open3"
require "rbconfig"

class DiagnosticsTest < Minitest::Test
  include AgentCatTestHelpers

  DIAGNOSTICS_ENV = %w[
    AGENTCAT_DISABLE_DIAGNOSTICS AGENTCAT_DIAGNOSTICS_ENDPOINT AGENTCAT_DIAGNOSTICS_TOKEN
    DISABLE_DIAGNOSTICS DIAGNOSTICS_ENDPOINT DIAGNOSTICS_TOKEN
  ].freeze
  # Saved and restored, not just deleted: they also decide test mode.
  DEPLOYMENT_ENV = %w[RAILS_ENV RACK_ENV ENVIRONMENT].freeze

  def setup
    AgentCat.reset!
    DIAGNOSTICS_ENV.each { |name| ENV.delete(name) }
    @saved_deployment_env = DEPLOYMENT_ENV.to_h { |name| [name, ENV.delete(name)] }
    AgentCat::Diagnostics.http_post = nil
  end

  # A leaked AGENTCAT_DISABLE_DIAGNOSTICS=false would send real beacons from other tests.
  def teardown
    DIAGNOSTICS_ENV.each { |name| ENV.delete(name) }
    @saved_deployment_env&.each { |name, value| value.nil? ? ENV.delete(name) : ENV[name] = value }
    AgentCat.reset!
    AgentCat::Diagnostics.http_post = nil
  end

  def test_disabled_in_test_environment_by_default
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    refute AgentCat::Diagnostics.enabled?
  end

  def test_disable_diagnostics_option_wins_over_forced_env
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: true)
    refute AgentCat::Diagnostics.enabled?
  end

  def test_env_force_enabled
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    assert AgentCat::Diagnostics.enabled?
  end

  def test_env_disabled
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "true"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    refute AgentCat::Diagnostics.enabled?
  end

  def test_env_off_words_are_trimmed_and_case_insensitive
    [" FALSE ", "0", "No", "off"].each do |word|
      AgentCat.reset!
      ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = word
      AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
      assert AgentCat::Diagnostics.enabled?, "expected #{word.inspect} to keep diagnostics on"
    end
  end

  def test_blank_env_is_unset
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "  "
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    refute AgentCat::Diagnostics.enabled?, "blank is unset: the test-environment default applies"
  end

  # The unprefixed TS name can only turn diagnostics off.
  def test_unprefixed_disable_diagnostics_cannot_force_them_on
    ENV["DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    refute AgentCat::Diagnostics.enabled?
  end

  def test_unprefixed_disable_diagnostics_turns_them_off_over_a_prefixed_false
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    ENV["DISABLE_DIAGNOSTICS"] = "1"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    refute AgentCat::Diagnostics.enabled?
  end

  def test_init_is_idempotent
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    AgentCat::Diagnostics.init(project_id: "proj_xxxxxxxxxxxxxxxxxxxxxxxxxxx", integration: "other", disabled: true)
    assert AgentCat::Diagnostics.enabled?
    assert_equal PROJECT_ID, attr_value(AgentCat::Diagnostics.static_attributes, "agentcat.project_id")
  end

  def test_static_attributes_with_project_id
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    attrs = AgentCat::Diagnostics.static_attributes
    assert_equal PROJECT_ID, attr_value(attrs, "agentcat.project_id")
    assert_nil attr_value(attrs, "agentcat.install_id")
    assert_equal "ruby", attr_value(attrs, "agentcat.sdk.language")
    assert_equal AgentCat::VERSION, attr_value(attrs, "agentcat.sdk.version")
    assert_equal MCP::VERSION, attr_value(attrs, "agentcat.mcp_sdk.version")
    assert_equal "official", attr_value(attrs, "agentcat.integration")
    assert_equal RUBY_VERSION, attr_value(attrs, "process.runtime.version")
  end

  def test_static_attributes_without_project_id_use_install_id
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: nil, integration: "ruby", disabled: false)
    attrs = AgentCat::Diagnostics.static_attributes
    assert_nil attr_value(attrs, "agentcat.project_id")
    install_id = attr_value(attrs, "agentcat.install_id")
    assert_match(/\A[0-9a-f]{16}\z/, install_id)
  end

  # Ruby values in the Node vocabulary.
  def test_static_attributes_use_the_node_vocabulary
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    attrs = AgentCat::Diagnostics.static_attributes
    uname = Etc.uname

    assert_equal AgentCat::Diagnostics.os_type(uname[:sysname]), attr_value(attrs, "os.type")
    assert_equal uname[:release], attr_value(attrs, "os.version")
    assert_equal AgentCat::Diagnostics.arch(uname[:machine]), attr_value(attrs, "host.arch")
    assert_equal Process.pid.to_s, attr_value(attrs, "process.pid")
    assert_equal "ruby", attr_value(attrs, "process.runtime.name")
    assert_nil attr_value(attrs, "host.cpu.count"), "host.cpu.count is not sent"
  end

  def test_os_type_maps_to_node_platform_names
    assert_equal "linux", AgentCat::Diagnostics.os_type("Linux")
    assert_equal "darwin", AgentCat::Diagnostics.os_type("Darwin")
    assert_equal "win32", AgentCat::Diagnostics.os_type("Windows_NT")
    assert_equal "win32", AgentCat::Diagnostics.os_type("MINGW64_NT-10.0")
    assert_equal "freebsd", AgentCat::Diagnostics.os_type("FreeBSD")
    assert_equal "sunos", AgentCat::Diagnostics.os_type("SunOS")
  end

  def test_arch_maps_to_node_arch_names
    assert_equal "x64", AgentCat::Diagnostics.arch("x86_64")
    assert_equal "x64", AgentCat::Diagnostics.arch("AMD64")
    assert_equal "arm64", AgentCat::Diagnostics.arch("aarch64")
    assert_equal "arm64", AgentCat::Diagnostics.arch("arm64")
    assert_equal "riscv64", AgentCat::Diagnostics.arch("riscv64")
  end

  def test_deployment_environment_prefers_rails_env_then_rack_env
    ENV["ENVIRONMENT"] = "from-environment"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    assert_nil attr_value(AgentCat::Diagnostics.static_attributes, "deployment.environment"),
      "ENVIRONMENT is not read"

    AgentCat.reset!
    ENV["RACK_ENV"] = "staging"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    assert_equal "staging", attr_value(AgentCat::Diagnostics.static_attributes, "deployment.environment")

    AgentCat.reset!
    ENV["RAILS_ENV"] = "production"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    assert_equal "production", attr_value(AgentCat::Diagnostics.static_attributes, "deployment.environment")
  end

  # Hostname + "|file://" + the gem root, so it is the same for every script
  # and working directory of one install.
  def test_install_id_hashes_hostname_and_gem_root
    gem_root = File.realpath(File.expand_path("..", __dir__))
    expected = Digest::SHA256.hexdigest("#{Socket.gethostname}|file://#{gem_root}")[0, 16]

    AgentCat::Diagnostics.init(project_id: nil, integration: "ruby", disabled: false)
    assert_equal expected, attr_value(AgentCat::Diagnostics.static_attributes, "agentcat.install_id")
  end

  def test_install_id_is_stable_across_cwd_and_program_name
    AgentCat::Diagnostics.init(project_id: nil, integration: "ruby", disabled: false)
    first = attr_value(AgentCat::Diagnostics.static_attributes, "agentcat.install_id")

    original_program = $PROGRAM_NAME
    Dir.chdir(Dir.tmpdir) do
      $PROGRAM_NAME = "bin/some-other-script"
      AgentCat.reset!
      AgentCat::Diagnostics.init(project_id: nil, integration: "ruby", disabled: false)
    end
    assert_equal first, attr_value(AgentCat::Diagnostics.static_attributes, "agentcat.install_id")
  ensure
    $PROGRAM_NAME = original_program if original_program
  end

  def test_record_buffers_and_flushes_otlp_payload
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    AgentCat::Diagnostics.record(:error, "AgentCat setup failed | bad id")
    AgentCat::Diagnostics.flush

    assert_equal 1, calls.size
    url = calls.first.fetch(:url)
    assert url.end_with?("/v1/logs"), "expected URL to end with /v1/logs, got #{url}"
    assert_equal "Bearer dgk_sdk_diag_3f9a2c7e1b8d4065af2e9c1d7b6a4f80", calls.first.fetch(:headers)["Authorization"]

    records = log_records(calls)
    assert_equal 1, records.size
    record = records.first
    assert_equal 17, record["severityNumber"]
    assert_equal "ERROR", record["severityText"]
    assert_equal "AgentCat setup failed | bad id", record["body"]["stringValue"]
    assert_match(/\A\d+\z/, record["timeUnixNano"])
    assert_equal "agentcat-diagnostics", calls.first.fetch(:body).dig("resourceLogs", 0, "scopeLogs", 0, "scope", "name")
    assert_equal 0, AgentCat::Diagnostics.buffer_size
  end

  def test_record_info_severity
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    AgentCat::Diagnostics.record(:info, "hello")
    AgentCat::Diagnostics.flush

    record = log_records(calls).first
    assert_equal 9, record["severityNumber"]
    assert_equal "INFO", record["severityText"]
    assert_equal "hello", record["body"]["stringValue"]
  end

  def test_record_warn_severity
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    AgentCat::Diagnostics.record(:warn, "watch out")
    AgentCat::Diagnostics.flush

    record = log_records(calls).first
    assert_equal 13, record["severityNumber"]
    assert_equal "WARN", record["severityText"]
    assert_equal "watch out", record["body"]["stringValue"]
  end

  def test_buffer_drops_oldest
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    1005.times { |i| AgentCat::Diagnostics.record(:info, "m#{i}") }
    AgentCat::Diagnostics.flush

    records = log_records(calls)
    assert_equal AgentCat::Diagnostics::MAX_BUFFER, records.size
    assert_equal "m5", records.first["body"]["stringValue"]
    assert_equal "m1004", records.last["body"]["stringValue"]
  end

  # An app's own DIAGNOSTICS_ENDPOINT / DIAGNOSTICS_TOKEN never reach AgentCat.
  def test_unprefixed_endpoint_and_token_are_not_read
    calls = stub_http
    ENV["DIAGNOSTICS_ENDPOINT"] = "https://example.test/collector"
    ENV["DIAGNOSTICS_TOKEN"] = "the-apps-own-secret"
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    AgentCat::Diagnostics.record(:error, "boom")
    AgentCat::Diagnostics.flush

    assert_equal "https://otel.agentcat.com/v1/logs", calls.first.fetch(:url)
    assert_equal "Bearer #{AgentCat::Diagnostics::DEFAULT_TOKEN}", calls.first.fetch(:headers)["Authorization"]
  end

  def test_endpoint_and_token_overrides
    calls = stub_http
    ENV["AGENTCAT_DIAGNOSTICS_ENDPOINT"] = "https://example.test/collector/"
    ENV["AGENTCAT_DIAGNOSTICS_TOKEN"] = "super-secret"
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)

    AgentCat::Diagnostics.record(:error, "boom")
    AgentCat::Diagnostics.flush

    assert_equal "https://example.test/collector/v1/logs", calls.first.fetch(:url)
    assert_equal "Bearer super-secret", calls.first.fetch(:headers)["Authorization"]
  end

  def test_track_emits_setup_beacons
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    server = build_server
    AgentCat.track(server, PROJECT_ID)

    AgentCat::Diagnostics.flush
    messages = log_records(calls).map { |record| record["body"]["stringValue"] }
    assert messages.any? { |m| m.start_with?("AgentCat setup started | project #{PROJECT_ID}") },
      "expected setup-started beacon, got #{messages.inspect}"
  end

  def test_track_without_project_id_reports_telemetry_only
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    server = build_server
    AgentCat.track(server)

    AgentCat::Diagnostics.flush
    messages = log_records(calls).map { |record| record["body"]["stringValue"] }
    assert messages.any? { |m| m.include?("project (telemetry-only)") },
      "expected (telemetry-only) beacon, got #{messages.inspect}"
  end

  def test_track_no_adapter_records_skipped
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    returned = AgentCat.track(Object.new, PROJECT_ID)

    assert_instance_of Object, returned
    AgentCat::Diagnostics.flush
    messages = log_records(calls).map { |record| record["body"]["stringValue"] }
    assert messages.any? { |m| m.start_with?("AgentCat setup skipped | no adapter for Object") },
      "expected skip beacon, got #{messages.inspect}"
  end

  # A malformed project ID does not raise; it records one warning.
  def test_malformed_project_id_records_a_warning_and_does_not_raise
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    server = build_server

    assert_same server, AgentCat.track(server, "not-a-project-id")
    AgentCat::Diagnostics.flush
    records = log_records(calls)
    warning = records.find { |record| record["body"]["stringValue"].start_with?("AgentCat setup warning | project_id \"not-a-project-id\"") }
    refute_nil warning, "expected setup-warning beacon, got #{records.map { |r| r["body"]["stringValue"] }.inspect}"
    assert_equal "WARN", warning["severityText"]
  end

  def test_delivery_failure_records_runtime_error
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    client = Object.new
    client.define_singleton_method(:post_event) { |_event| nil }

    AgentCat::Delivery.publish(client, {project_id: PROJECT_ID})
    AgentCat::Diagnostics.flush

    messages = log_records(calls).map { |record| record["body"]["stringValue"] }
    expected = "AgentCat runtime error | event publish failed after 4 attempts | project #{PROJECT_ID}"
    assert messages.any? { |m| m == expected },
      "expected runtime-error beacon, got #{messages.inspect}"
  end

  def test_reset_clears_state_and_allows_reinit
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    AgentCat::Diagnostics.record(:error, "boom")
    assert_equal 1, AgentCat::Diagnostics.buffer_size

    AgentCat.reset!
    refute AgentCat::Diagnostics.enabled?
    assert_equal 0, AgentCat::Diagnostics.buffer_size

    AgentCat::Diagnostics.init(project_id: nil, integration: "official", disabled: true)
    refute AgentCat::Diagnostics.enabled?
  end

  # 250 ms connect, 1 s total. A collector that accepts and never answers holds
  # the flush for about a second, not the old 5 s + 5 s.
  def test_flush_gives_up_on_a_silent_collector_within_the_total_deadline
    assert_equal 0.25, AgentCat::Diagnostics::CONNECT_TIMEOUT
    assert_equal 1.0, AgentCat::Diagnostics::TOTAL_TIMEOUT

    with_silent_server do |port|
      ENV["AGENTCAT_DIAGNOSTICS_ENDPOINT"] = "http://127.0.0.1:#{port}"
      ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
      AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
      AgentCat::Diagnostics.record(:error, "boom")

      started = AgentCat::Clock.monotonic_now
      AgentCat::Diagnostics.flush
      elapsed = AgentCat::Clock.monotonic_now - started

      assert_operator elapsed, :>=, 0.9
      assert_operator elapsed, :<, 1.5
    end
  end

  # A setup record goes out on AgentCat.flush, not 2 s later on the batch timer.
  def test_agentcat_flush_sends_a_setup_record_without_the_batch_delay
    calls = stub_http
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"

    AgentCat.track(build_server, "not-a-project-id")
    started = AgentCat::Clock.monotonic_now
    assert AgentCat.flush(timeout: 1)
    elapsed = AgentCat::Clock.monotonic_now - started

    assert_operator elapsed, :<, AgentCat::Diagnostics::FLUSH_DELAY
    messages = log_records(calls).map { |record| record["body"]["stringValue"] }
    assert messages.any? { |m| m.start_with?("AgentCat setup warning |") }, messages.inspect
  end

  def test_at_exit_flush_budget_is_five_seconds
    assert_equal 5, AgentCat::AT_EXIT_FLUSH_TIMEOUT
  end

  # A process whose only AgentCat call is a `track` that goes nowhere still sends its
  # setup records when it exits: `track` registers the at_exit flush, not just the
  # event queue.
  def test_at_exit_sends_the_setup_records_of_a_process_that_exits
    script = <<~RUBY
      require "agentcat"
      AgentCat.logger = Logger.new(File::NULL)
      AgentCat::Diagnostics.http_post = lambda do |_url, _headers, body|
        $stdout.puts(body)
        $stdout.flush
        [200, "ok"]
      end
      AgentCat.track(Object.new, "not-a-project-id")
    RUBY
    env = {"AGENTCAT_DISABLE_DIAGNOSTICS" => "false", "AGENTCAT_ENABLED" => nil, "RAILS_ENV" => nil, "RACK_ENV" => nil, "APP_ENV" => nil}
    lib = File.expand_path("../lib", __dir__)
    out, status = Open3.capture2(env, RbConfig.ruby, "-I", lib, "-e", script)

    assert status.success?
    assert_includes out, "AgentCat setup warning | project_id"
    assert_includes out, "AgentCat setup skipped | no adapter for Object"
  end

  # A sender that blows up must cost us just that batch - no exception back into the
  # host, and no stale records resent on the next flush.
  def test_flush_swallows_a_failing_sender_and_drops_the_batch
    ENV["AGENTCAT_DISABLE_DIAGNOSTICS"] = "false"
    AgentCat::Diagnostics.init(project_id: PROJECT_ID, integration: "official", disabled: false)
    AgentCat::Diagnostics.http_post = ->(*) { raise IOError, "connection reset" }

    AgentCat::Diagnostics.record(:error, "first")
    AgentCat::Diagnostics.flush
    assert_equal 0, AgentCat::Diagnostics.buffer_size

    calls = stub_http
    AgentCat::Diagnostics.record(:error, "second")
    AgentCat::Diagnostics.flush

    assert_equal ["second"], log_records(calls).map { |record| record["body"]["stringValue"] }
  end

  def test_debug_mode_appends_to_agentcat_log_in_home
    with_home(Dir.mktmpdir) do |home|
      AgentCat.debug = true

      AgentCat::Diagnostics.record(:warn, "slow hook")
      AgentCat::Diagnostics.record(:debug, "local only")

      lines = File.readlines(File.join(home, "agentcat.log"), chomp: true)
      assert_equal 2, lines.size
      assert_match(/\A\[agentcat\] \d{4}-\d\d-\d\dT\S+ WARN: slow hook\z/, lines[0])
      assert_match(/DEBUG: local only\z/, lines[1])
    end
  end

  def test_debug_log_is_not_written_when_debug_is_off
    with_home(Dir.mktmpdir) do |home|
      AgentCat::Diagnostics.record(:warn, "slow hook")

      refute File.exist?(File.join(home, "agentcat.log"))
    end
  end

  def test_unwritable_debug_log_never_raises
    with_home(File.join(Dir.tmpdir, "agentcat-missing-#{Process.pid}", "nope")) do |home|
      AgentCat.debug = true

      AgentCat::Diagnostics.record(:warn, "slow hook")

      refute File.exist?(home)
    end
  end

  private

  def with_home(dir)
    original = ENV["HOME"]
    ENV["HOME"] = dir
    yield dir
  ensure
    ENV["HOME"] = original
    AgentCat.debug = false
    FileUtils.rm_rf(dir) if dir.start_with?(Dir.tmpdir)
  end

  # Accepts connections and never writes a byte back.
  def with_silent_server
    server = TCPServer.new("127.0.0.1", 0)
    clients = []
    acceptor = Thread.new { loop { clients << server.accept } }
    yield server.addr[1]
  ensure
    acceptor&.kill
    clients&.each(&:close)
    server&.close
  end

  def stub_http
    calls = []
    AgentCat::Diagnostics.http_post = lambda do |url, headers, body|
      calls << {url: url, headers: headers, body: JSON.parse(body)}
      [200, "ok"]
    end
    calls
  end

  def log_records(calls)
    payload = calls.last.fetch(:body)
    payload.dig("resourceLogs", 0, "scopeLogs", 0, "logRecords") || []
  end

  def attr_value(attributes, key)
    attributes.each { |entry| return entry["value"]["stringValue"] if entry["key"] == key }
    nil
  end
end
