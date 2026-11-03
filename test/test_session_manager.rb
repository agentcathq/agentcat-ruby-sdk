require_relative "test_helper"

class SessionManagerTest < Minitest::Test
  def test_mint_produces_a_valid_shaped_id
    sid = AgentCat::SessionManager.mint_session_id

    assert sid.start_with?("ses_")
    assert_equal 31, sid.length # "ses_" + 27 base62 chars
    assert AgentCat::SessionManager.valid?(sid)
  end

  def test_malformed_inputs_are_invalid
    [nil, 42, "", "ses_", "ses_abc", "ses_#{"a" * 26}", "ses_#{"a" * 28}", "abc.def", "start"].each do |input|
      refute AgentCat::SessionManager.valid?(input), input.inspect
    end
  end

  def test_start_sentinel_is_recognised_case_and_whitespace_insensitively
    ["start", "Start", "START", "  start  ", " StArT\t"].each do |input|
      assert AgentCat::SessionManager.start_sentinel?(input), input.inspect
    end

    refute AgentCat::SessionManager.start_sentinel?("started")
    refute AgentCat::SessionManager.start_sentinel?(nil)
  end

  def test_session_ids_are_unique
    ids = Array.new(50) { AgentCat::SessionManager.mint_session_id }

    assert_equal 50, ids.uniq.size
    assert(ids.all? { |id| AgentCat::SessionManager.valid?(id) })
  end

  # Golden vectors pinned byte-for-byte against the Go SDK's `DeriveSessionID`
  # (github.com/agentcathq/agentcat-go-sdk, internal/handles/handles.go) — the
  # Ruby, Go, and TypeScript SDKs must derive identical ids from identical
  # inputs. Any change here is a cross-SDK compatibility break.
  def test_derive_session_id_golden_vectors
    vectors = {
      ["host-hello", nil] => "ses_2c1V8GAwWGUw14vlZO5SpMyMknb",
      ["host-hello", PROJECT_ID] => "ses_2brEm6m7DoKUNNy6eirTf6ARaxy",
      ["host-hosted", nil] => "ses_2cUXKHAoJxnT53BzqfWGGsyOUCc",
      ["host-hosted", PROJECT_ID] => "ses_2bTbnEB4R6WGc8cMqqWleL2Nili",
      ["chat-12345", nil] => "ses_2bkXqTJy4IImverm7VueEdIJOhY",
      ["chat-12345", PROJECT_ID] => "ses_2bDgLHQSSDqMPqcdkmjQSY2CeiY",
      ["a", nil] => "ses_2c7cbGRCDeGexo7xoSUJAd4BmXo",
      ["some user-session:with:colons", nil] => "ses_2arPJxgTKbZmHHuM4qb7wFZx0QP"
    }

    vectors.each do |(customer_id, project_id), expected|
      assert_equal expected, AgentCat::SessionManager.derive_session_id(customer_id, project_id),
        "derive_session_id(#{customer_id.inspect}, #{project_id.inspect}) drifted from the Go SDK"
      assert AgentCat::SessionManager.valid?(expected)
    end
  end

  def test_derive_session_id_is_deterministic_and_project_scoped
    derived = AgentCat::SessionManager.derive_session_id("chat-12345", PROJECT_ID)

    assert_equal derived, AgentCat::SessionManager.derive_session_id("chat-12345", PROJECT_ID)
    assert_equal derived, AgentCat::SessionManager.derive_session_id("chat-12345", PROJECT_ID)
    refute_equal derived, AgentCat::SessionManager.derive_session_id("chat-12345", nil)
    refute_equal derived, AgentCat::SessionManager.derive_session_id("chat-12345", "proj_222222222222222222222222222")
    refute_equal derived, AgentCat::SessionManager.derive_session_id("chat-12346", PROJECT_ID)
  end

  def test_derive_session_id_with_empty_project_ignores_project_id
    with_project = AgentCat::SessionManager.derive_session_id("topic-1", "")
    without_project = AgentCat::SessionManager.derive_session_id("topic-1", nil)

    assert_equal without_project, with_project
    assert AgentCat::SessionManager.valid?(with_project)
  end
end
