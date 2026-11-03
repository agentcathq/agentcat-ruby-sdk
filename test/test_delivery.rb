require_relative "test_helper"

class DeliveryTest < Minitest::Test
  class FlakyClient
    attr_reader :calls

    def initialize(failures_before_success:)
      @failures_before_success = failures_before_success
      @calls = 0
    end

    def post_event(_event)
      @calls += 1
      return nil if @calls <= @failures_before_success

      {"status" => "accepted"}
    end
  end

  def test_succeeds_on_the_first_try
    client = FlakyClient.new(failures_before_success: 0)

    AgentCat::Delivery.publish(client, {})

    assert_equal 1, client.calls
  end

  def test_retries_until_it_succeeds
    client = FlakyClient.new(failures_before_success: 3)

    AgentCat::Delivery.publish(client, {})

    assert_equal 4, client.calls
  end

  def test_gives_up_after_max_retries_past_the_initial_attempt
    client = FlakyClient.new(failures_before_success: 100)

    AgentCat::Delivery.publish(client, {})

    # initial attempt + 3 retries, matching the reference SDKs
    assert_equal AgentCat::Delivery::DEFAULT_MAX_RETRIES + 1, client.calls
  end

  def test_max_retries_is_configurable
    client = FlakyClient.new(failures_before_success: 100)

    AgentCat::Delivery.publish(client, {}, max_retries: 1)

    assert_equal 2, client.calls
  end

  def test_backoff_grows_and_stays_within_its_jitter_bounds
    first = AgentCat::Delivery.backoff(1)
    second = AgentCat::Delivery.backoff(2)

    assert_operator first, :>=, AgentCat::Delivery::DEFAULT_BASE_DELAY_SECONDS
    assert_operator first, :<, AgentCat::Delivery::DEFAULT_BASE_DELAY_SECONDS * 1.25
    assert_operator second, :>, first
  end

  def test_backoff_doubles_from_a_custom_base
    first = AgentCat::Delivery.backoff(2, base: 2)

    assert_operator first, :>=, 4.0
    assert_operator first, :<, 4.0 * 1.25
  end
end
