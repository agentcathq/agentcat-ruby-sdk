require_relative "test_helper"

# `stateless` is deprecated (see AgentCat::Options#stateless) but still works until it is
# removed. The identify tests are in test_identify.rb.
class StatelessTest < Minitest::Test
  include AgentCatTestHelpers

  def test_stateless_mode_does_not_inject_session_id
    server = build_server
    track(server, project_id: PROJECT_ID, stateless: true)

    refute listed_tool(server, "echo")[:inputSchema][:properties].key?(:session_id)
  end

  def test_stateless_mode_sends_no_session_id_and_no_mint_back
    server = build_server
    client = track(server, project_id: PROJECT_ID, stateless: true)

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal ["hello"], texts_of(result)
    refute result.key?(:_meta)
    assert_nil client.last_event.fetch(:session_id)
  end

  def test_stateless_true_logs_a_deprecation_warning
    log = StringIO.new
    with_logger(Logger.new(log, level: Logger::WARN)) do
      AgentCat::Options.new(stateless: true)
    end

    assert_match(/stateless.*deprecated/i, log.string)
  end

  def test_stateless_false_does_not_warn
    log = StringIO.new
    with_logger(Logger.new(log, level: Logger::WARN)) do
      AgentCat::Options.new(stateless: false)
      AgentCat::Options.new
    end

    assert_empty log.string
  end

  private

  def with_logger(logger)
    previous = AgentCat.logger
    AgentCat.logger = logger
    yield
  ensure
    AgentCat.logger = previous
  end
end
