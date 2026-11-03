require_relative "test_helper"
require "json"
require_relative "../scripts/mcp_versions"

# The `mcp compat` workflow's discovery step. It reads the versions
# from rubygems.org at run time; this fixture stands in for that API response.
class TestMcpVersions < Minitest::Test
  FIXTURE = File.expand_path("fixtures/mcp_versions.json", __dir__)
  RUBIES = %w[3.1 3.3 3.4].freeze

  def entries
    JSON.parse(File.read(FIXTURE))
  end

  def test_picks_the_floor_and_the_newest_patch_of_every_minor_at_or_above_it
    picked = McpVersions.pick(entries, floor: "0.23.0").map(&:number)

    # Not 2.0.0.pre1 (prerelease), 1.4.0.1 (not X.Y.Z), 0.22.0 and 0.4.0 (below the floor),
    # nor the older patches 1.8.0, 1.8.1, 1.6.0. The floor 0.23.0 stays next to its newest patch 0.23.1.
    assert_equal %w[0.23.0 0.23.1 0.24.0 1.0.0 1.5.0 1.6.1 1.7.0 1.8.2], picked
  end

  def test_keeps_the_ruby_platform_entry_when_a_version_has_several
    picked = McpVersions.pick(entries, floor: "0.23.0").find { |release| release.number == "1.5.0" }

    assert_equal ">= 3.1.4", picked.ruby_version
  end

  def test_matrix_skips_the_rubies_a_version_does_not_support
    matrix = McpVersions.matrix(entries, floor: "0.23.0", rubies: RUBIES)
    pairs = matrix.map { |row| [row["mcp"], row["ruby"]] }

    refute_includes pairs, ["1.7.0", "3.1"], "1.7.0 needs Ruby >= 3.2.0"
    assert_includes pairs, ["1.7.0", "3.3"]
    refute_includes pairs, ["1.6.1", "3.4"], "1.6.1 needs Ruby < 3.4"
    assert_includes pairs, ["1.6.1", "3.1"]
    # setup-ruby installs the newest patch of a minor, so ">= 3.1.4" runs on "3.1".
    assert_includes pairs, ["1.5.0", "3.1"]
    # No ruby_version in the API: no constraint.
    assert_equal RUBIES, matrix.select { |row| row["mcp"] == "1.0.0" }.map { |row| row["ruby"] }
    assert_equal 8 * 3 - 2, matrix.size
  end

  def test_rejects_a_floor_with_no_release
    error = assert_raises(McpVersions::Error) { McpVersions.pick(entries, floor: "9.0.0") }

    assert_match "9.0.0", error.message
  end

  def test_reads_the_floor_from_the_gemspec_runtime_dependency
    gemspec = File.expand_path("../agentcat.gemspec", __dir__)

    assert_equal "0.23.0", McpVersions.floor(gemspec)
  end

  def test_rejects_a_floor_that_is_not_a_single_minimum
    spec = Gem::Specification.new { |s| s.add_runtime_dependency "mcp", "~> 1.0" }

    assert_raises(McpVersions::Error) { McpVersions.floor_of(spec) }
  end
end
