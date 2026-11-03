require_relative "test_helper"

# `identify` resolves the event's actor and works the same whether or not a session is in
# play.
class IdentifyTest < Minitest::Test
  include AgentCatTestHelpers

  def test_identify_reports_actor_on_every_call
    server = build_server
    identify = ->(tool_call) { AgentCat::UserIdentity.new(user_id: "user-#{tool_call.arguments["msg"]}", user_name: "Ann", user_data: {plan: "pro"}) }
    client = track(server, project_id: PROJECT_ID, identify: identify)

    tool_result(server, "echo", {msg: "hello"})

    event = client.last_event
    assert_equal "user-hello", event[:actor_id]
    assert_equal "user-hello", event[:identify_actor_given_id]
    assert_equal "Ann", event[:identify_actor_name]
    assert_equal({plan: "pro"}, event[:identify_data])
  end

  def test_identify_takes_precedence_over_agent_id
    server = build_server
    identify = ->(*) { AgentCat::UserIdentity.new(user_id: "identified-user") }
    client = track(server, project_id: PROJECT_ID, identify: identify, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "agent-1"})

    assert_equal "identified-user", client.last_event[:actor_id]
  end

  def test_agent_id_is_used_when_identify_is_absent
    server = build_server
    client = track(server, project_id: PROJECT_ID, enable_agent_tracking: true)

    tool_result(server, "echo", {msg: "hello", agent_id: "agent-1"})

    assert_equal "agent-1", client.last_event[:actor_id]
  end

  def test_failing_identify_does_not_break_the_tool_call
    server = build_server
    client = track(server, project_id: PROJECT_ID, identify: ->(*) { raise "boom" })

    result = tool_result(server, "echo", {msg: "hello"})

    assert_equal "hello", texts_of(result).last
    assert_nil client.last_event[:actor_id]
  end

  def test_non_user_identity_return_value_is_ignored
    server = build_server
    client = track(server, project_id: PROJECT_ID, identify: ->(*) { {user_id: "wrong-shape"} })

    tool_result(server, "echo", {msg: "hello"})

    assert_nil client.last_event[:actor_id]
  end
end
