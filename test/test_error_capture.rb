require_relative "test_helper"

class ErrorCaptureTest < Minitest::Test
  def raise_here
    raise "boom"
  end

  def test_captures_message_type_and_platform
    begin
      raise_here
    rescue => e
      captured = AgentCat::ErrorCapture.capture(e)
    end

    assert_equal "boom", captured["message"]
    assert_equal "RuntimeError", captured["type"]
    assert_equal "ruby", captured["platform"]
  end

  def test_captures_stack_and_structured_frames
    begin
      raise_here
    rescue => e
      captured = AgentCat::ErrorCapture.capture(e)
    end

    assert_kind_of String, captured["stack"]
    assert_includes captured["stack"], "raise_here"

    frame = captured["frames"].find { |f| f["function"].to_s.include?("raise_here") }
    refute_nil frame, "expected a frame for raise_here in #{captured["frames"].inspect}"
    assert_equal __FILE__, frame["filename"]
    assert_kind_of Integer, frame["lineno"]
    assert_equal true, frame["in_app"]
  end

  def test_frames_from_library_path_are_not_in_app
    gem_dir = Gem.path.first
    refute AgentCat::ErrorCapture.send(:in_app?, File.join(gem_dir, "gems/whatever/lib/thing.rb"))
  end

  def test_frames_from_app_path_are_in_app
    assert AgentCat::ErrorCapture.send(:in_app?, "/Users/someone/app/lib/thing.rb")
  end

  def test_nil_path_is_treated_as_in_app
    assert AgentCat::ErrorCapture.send(:in_app?, nil)
  end

  def test_captures_the_cause_chain
    begin
      begin
        raise "root cause"
      rescue
        raise "wrapper"
      end
    rescue => e
      captured = AgentCat::ErrorCapture.capture(e)
    end

    assert_equal "wrapper", captured["message"]
    refute_nil captured["chained_errors"]
    assert_equal 1, captured["chained_errors"].size
    assert_equal "root cause", captured["chained_errors"].first["message"]
    assert_equal "RuntimeError", captured["chained_errors"].first["type"]
  end

  def test_no_chained_errors_key_when_there_is_no_cause
    begin
      raise_here
    rescue => e
      captured = AgentCat::ErrorCapture.capture(e)
    end

    refute captured.key?("chained_errors")
  end

  def test_cause_cycle_does_not_infinite_loop
    a = RuntimeError.new("a")
    b = RuntimeError.new("b")
    a.define_singleton_method(:cause) { b }
    b.define_singleton_method(:cause) { a }

    captured = AgentCat::ErrorCapture.capture(a)

    # Each node is captured once before the cycle is detected on the second pass through it.
    assert_equal 2, captured["chained_errors"].size
  end

  def test_chain_depth_is_capped
    innermost = RuntimeError.new("innermost")
    chain = (AgentCat::PayloadLimits::MAX_CHAIN_DEPTH + 5).times.reduce(innermost) do |cause, i|
      error = RuntimeError.new("layer#{i}")
      error.define_singleton_method(:cause) { cause }
      error
    end

    captured = AgentCat::ErrorCapture.capture(chain)

    assert_equal AgentCat::PayloadLimits::MAX_CHAIN_DEPTH, captured["chained_errors"].size
  end

  def recurse(depth)
    depth.zero? ? raise("deep") : recurse(depth - 1)
  end

  def test_stack_frames_are_truncated_to_the_configured_limit
    begin
      recurse(AgentCat::PayloadLimits::MAX_STACK_FRAMES + 20)
    rescue => e
      captured = AgentCat::ErrorCapture.capture(e)
    end

    assert_equal AgentCat::PayloadLimits::MAX_STACK_FRAMES, captured["frames"].size
  end

  def test_a_message_that_raises_falls_back_to_a_minimal_payload
    error = RuntimeError.new("will be replaced")
    error.define_singleton_method(:message) { raise "message blew up" }

    captured = AgentCat::ErrorCapture.capture(error)

    assert_equal "RuntimeError", captured["type"]
    assert_equal "ruby", captured["platform"]
    refute_nil captured["message"]
  end

  def test_error_with_no_backtrace_omits_stack_and_frames
    error = RuntimeError.new("never raised")

    captured = AgentCat::ErrorCapture.capture(error)

    refute captured.key?("stack")
    refute captured.key?("frames")
  end
end
