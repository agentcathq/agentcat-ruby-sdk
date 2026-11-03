require_relative "test_helper"

class OptionsTest < Minitest::Test
  include AgentCatTestHelpers

  def test_pipeline_defaults_match_the_reference_sdks
    options = AgentCat::Options.new

    assert_equal 10_000, options.queue_size
    assert_equal 3, options.max_retries
    assert_equal 1.0, options.retry_base_delay
    assert_equal 10, options.request_timeout
  end

  def test_pipeline_defaults_are_configurable
    options = AgentCat::Options.new(
      queue_size: 5,
      max_retries: 7,
      retry_base_delay: 0.5,
      request_timeout: 2.5
    )

    assert_equal 5, options.queue_size
    assert_equal 7, options.max_retries
    assert_equal 0.5, options.retry_base_delay
    assert_equal 2.5, options.request_timeout
  end

  def test_client_uses_the_real_client_by_default
    options = AgentCat::Options.new

    assert options.default_client?
    assert_equal AgentCat::Client, options.client
  end

  def test_custom_client_is_not_default
    client = RecordingClient.new
    options = AgentCat::Options.new(client: client)

    refute options.default_client?
    assert_same client, options.client
  end

  # A bad value logs one WARN line and falls back to the default. A
  # value of the wrong Ruby type still fails fast in the Sorbet sig.
  def test_bad_queue_size_warns_and_uses_the_default
    [0, -1].each do |bad|
      options = nil
      log = capture_log { options = AgentCat::Options.new(queue_size: bad) }

      assert_equal AgentCat::Options::DEFAULT_QUEUE_SIZE, options.queue_size
      assert_equal ["WARN: Options#queue_size must be at least 1, got #{bad}; using the default 10000"], log.lines(chomp: true)
    end
    assert_raises(TypeError) { AgentCat::Options.new(queue_size: 1.5) }
  end

  def test_bad_max_retries_warns_and_uses_the_default
    options = nil
    log = capture_log { options = AgentCat::Options.new(max_retries: -1) }

    assert_equal 3, options.max_retries
    assert_equal ["WARN: Options#max_retries must be 0 or more, got -1; using the default 3"], log.lines(chomp: true)
    assert_raises(TypeError) { AgentCat::Options.new(max_retries: 1.5) }
  end

  def test_bad_retry_base_delay_warns_and_uses_the_default
    [0, -0.5, Float::NAN].each do |bad|
      options = nil
      log = capture_log { options = AgentCat::Options.new(retry_base_delay: bad) }

      assert_equal 1.0, options.retry_base_delay
      assert_equal 1, log.lines.size
      assert_match(/\AWARN: Options#retry_base_delay must be a positive number, got .*; using the default 1\.0/, log)
    end
  end

  def test_bad_request_timeout_warns_and_uses_the_default
    [0, -10].each do |bad|
      options = nil
      log = capture_log { options = AgentCat::Options.new(request_timeout: bad) }

      assert_equal 10.0, options.request_timeout
      assert_equal ["WARN: Options#request_timeout must be a positive number, got #{bad}; using the default 10.0"], log.lines(chomp: true)
    end
    assert_raises(TypeError) { AgentCat::Options.new(request_timeout: "10") }
  end

  def test_good_values_log_nothing
    log = capture_log do
      AgentCat::Options.new(queue_size: 5, max_retries: 0, retry_base_delay: 0.1, request_timeout: 2,
        hook_timeout: 0.5, api_base_url: "https://stage.example.com", event_tags: ->(*) {})
    end

    assert_empty log
  end

  def test_api_base_url_defaults_to_nil
    assert_nil AgentCat::Options.new.api_base_url
  end

  def test_api_base_url_accepts_an_absolute_http_url
    options = AgentCat::Options.new(api_base_url: "https://stage.example.com:8443/api")

    assert_equal "https://stage.example.com:8443/api", options.api_base_url
  end

  def test_a_relative_or_malformed_api_base_url_warns_and_is_ignored
    ["not a url", "/just/a/path", "ftp://example.com", "http://"].each do |bad|
      options = nil
      log = capture_log { options = AgentCat::Options.new(api_base_url: bad) }

      assert_nil options.api_base_url, bad
      assert_equal ["WARN: Options#api_base_url must be an absolute http(s) URL, got #{bad.inspect}; using the default endpoint"], log.lines(chomp: true)
    end
    assert_raises(TypeError) { AgentCat::Options.new(api_base_url: :symbol) }
  end
end
