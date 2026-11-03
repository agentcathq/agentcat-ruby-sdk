require_relative "test_helper"

class EventIdTest < Minitest::Test
  BODY_PATTERN = /\Aevt_[0-9A-Za-z]{27}\z/

  def test_mint_produces_a_valid_shaped_id
    id = AgentCat::EventId.mint

    assert_match BODY_PATTERN, id
    assert_equal 4 + 27, id.length # "evt_" + 27 base62 chars
  end

  def test_event_ids_are_unique
    ids = Array.new(50) { AgentCat::EventId.mint }

    assert_equal 50, ids.uniq.size
    assert(ids.all? { |id| id.match?(BODY_PATTERN) })
  end

  def test_event_ids_share_the_session_ksuid_scheme
    event_id = AgentCat::EventId.mint
    body = event_id.delete_prefix("evt_")

    assert_equal 27, body.length
    assert AgentCat::SessionManager.valid?("ses_#{body}") # same KSUID body as sessions
  end
end
