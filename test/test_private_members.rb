require_relative "test_helper"
require "minitest/mock"
require "open3"

# Every `mcp` gem internal AgentCat touches is listed in
# `AgentCat::PrivateMembers`, checked against the installed gem, and turns only its own
# feature off when it is missing.
class PrivateMembersTest < Minitest::Test
  include AgentCatTestHelpers

  Members = AgentCat::PrivateMembers

  # The by-name check: CI runs this against every `mcp` version in the matrix, so a
  # release that drops or renames a member fails here with that member's name.
  Members::ALL.each do |member|
    define_method("test_#{member.owner.gsub("::", "_")}_#{member.name.delete("@")}_is_on_the_installed_mcp_gem") do
      assert_equal true, Members.probe(member), "#{member.label} (#{member.kind}) is missing from mcp #{MCP::VERSION}; #{Members::FEATURES.fetch(member.feature)} depends on it"
    end
  end

  # MCP::ServerContext has no autoload: only mcp/server.rb loads it. In a fresh process
  # where nothing touched MCP::Server yet, the probe must still find it, whatever
  # order the tests run in.
  def test_probes_server_context_in_a_process_that_has_not_loaded_mcp_server
    script = <<~RUBY
      require "mcp"
      require "agentcat"
      abort "MCP::ServerContext is already loaded" if MCP.const_defined?(:ServerContext, false)
      members = AgentCat::PrivateMembers
      puts [members::SERVER_CONTEXT_NOTIFICATION_TARGET, members::SERVER_CONTEXT_RELATED_REQUEST_ID].map { |m| members.probe(m) }.inspect
    RUBY
    output, error, status = Open3.capture3(RbConfig.ruby, "-I", File.expand_path("../lib", __dir__), "-e", script)

    assert status.success?, error
    assert_equal "[true, true]", output.strip
  end

  def test_every_member_names_a_known_feature_and_kind
    Members::ALL.each do |member|
      assert Members::FEATURES.key?(member.feature), "#{member.label}: unknown feature #{member.feature}"
      assert_includes %i[ivar private_method method internal_hash], member.kind, member.label
    end
  end

  # No literal member name outside the manifest: each use site goes through a constant.
  def test_use_sites_name_members_through_the_manifest
    sources = Dir[File.expand_path("../lib/**/*.rb", __dir__)].reject { |path| path.end_with?("private_members.rb") }
    offenders = sources.select { |path| File.read(path).match?(/instance_variable_(get|defined\?)\(:@(related_request_id|notification_target)/) }
    assert_empty offenders
  end

  def test_track_checks_the_manifest_once_and_logs_nothing_when_every_member_is_there
    calls = 0
    probe = Members.method(:probe)
    log = Members.stub(:probe, ->(member) {
      calls += 1
      probe.call(member)
    }) do
      capture_log(level: Logger::WARN) do
        track(build_server)
        track(build_server)
      end
    end

    assert_equal "", log
    assert_equal Members::ALL.size, calls
    Members::ALL.map(&:feature).uniq.each { |feature| assert Members.enabled?(feature), feature.to_s }
  end

  def test_a_missing_member_logs_one_error_line_turns_its_feature_off_and_calls_still_work
    log = stub_missing(Members::SERVER_CONTEXT_RELATED_REQUEST_ID) do
      capture_log do
        @server = build_server
        @client = track(@server, project_id: PROJECT_ID)
        track(build_server)
      end
    end

    lines = log.lines.grep(/related_request_id/)
    assert_equal 1, lines.size, log
    assert_match(/\AERROR: .*MCP::ServerContext@related_request_id.* mcp #{Regexp.escape(MCP::VERSION)}.*requestId/o, lines.first)
    refute Members.enabled?(:request_id)
    assert Members.enabled?(:request_headers)

    result = tool_result(@server, "echo", {msg: "hi"})
    assert_includes texts_of(result), "hi"
    event = @client.last_event
    refute_nil event
    refute event[:parameters].fetch("extra", {}).key?("requestId")
  end

  def test_a_missing_tools_hash_turns_instrumentation_off_and_the_server_still_answers
    stub_missing(Members::SERVER_TOOLS) do
      capture_log do
        @server = build_server
        @client = track(@server, project_id: PROJECT_ID)
      end
    end

    refute listed_tool(@server, "echo")[:inputSchema][:properties].key?(:session_id)
    result = tool_result(@server, "echo", {msg: "hi"})
    assert_equal ["hi"], texts_of(result)
    assert_empty @client.events
  end

  # Without the InputSchema overrides the injected parameters would be hard-required,
  # so they are listed but not required, and a call without them still runs.
  def test_missing_input_schema_overrides_leave_injected_parameters_optional
    stub_missing(Members::INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS) do
      capture_log do
        @server = build_server
        @client = track(@server, project_id: PROJECT_ID)
      end
    end

    schema = listed_tool(@server, "echo")[:inputSchema]
    assert schema[:properties].key?(:session_id)
    assert_equal ["msg"], schema[:required]
    response = @server.handle({jsonrpc: "2.0", id: 2, method: "tools/call", params: {name: "echo", arguments: {msg: "hi"}}})
    refute response[:result][:isError]
    AgentCat.flush(timeout: 1)
    assert_equal 1, @client.events.size
  end

  # The hook is process-wide and may already be in place from an earlier `track`, so with
  # its feature off it passes every request straight through.
  def test_a_missing_transport_member_turns_header_capture_off
    stub_missing(Members::STREAMABLE_HTTP_TRANSPORT_CALL) do
      capture_log { track(build_server) }
    end
    transport = Class.new { def call(_env) = AgentCat::RequestContext.current }
    transport.prepend(AgentCat::RequestContext::TransportHook)

    refute Members.enabled?(:request_headers)
    assert_nil transport.new.call({"HTTP_USER_AGENT" => "probe", "REQUEST_METHOD" => "POST"})
    AgentCat.reset!
    refute_nil transport.new.call({"HTTP_USER_AGENT" => "probe", "REQUEST_METHOD" => "POST"})
  end

  # Runtime vanish: a real `MCP::ServerContext` without the ivar turns the feature off
  # with one line, and the call goes on.
  def test_an_ivar_gone_at_run_time_turns_its_feature_off_once
    server = build_server
    client = track(server, project_id: PROJECT_ID)
    handle = server.tools["echo"]
    context = MCP::ServerContext.new(nil, progress: nil, notification_target: nil, related_request_id: 7)
    context.remove_instance_variable(:@related_request_id)

    log = capture_log do
      2.times { handle.call({"msg" => "hi", "session_id" => "start"}, server_context: context) }
      AgentCat.flush(timeout: 1)
    end

    assert_equal 1, log.lines.grep(/ERROR: .*@related_request_id/).size, log
    refute Members.enabled?(:request_id)
    assert_equal 2, client.events.size
  end

  def test_a_host_stand_in_without_the_ivar_does_not_turn_the_feature_off
    server = build_server
    track(server, project_id: PROJECT_ID)

    log = capture_log { server.tools["echo"].call({"msg" => "hi", "session_id" => "start"}, server_context: {}) }

    assert_equal "", log.lines.grep(/ERROR/).join
    assert Members.enabled?(:request_id)
  end

  private

  def stub_missing(missing, &block)
    probe = Members.method(:probe)
    Members.stub(:probe, ->(member) { member.equal?(missing) ? false : probe.call(member) }, &block)
  end
end
