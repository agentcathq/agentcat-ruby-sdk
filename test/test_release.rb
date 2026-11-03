require_relative "test_helper"
require "fileutils"
require "open3"
require "tmpdir"
require_relative "../scripts/release"

# The steps of .github/workflows/release.yml (scripts/release.rb), as in the Java and Rust SDKs.
class TestRelease < Minitest::Test
  ROOT = File.expand_path("..", __dir__)
  REPO = "https://github.com/agentcathq/agentcat-ruby-sdk"

  CHANGELOG_TEXT = <<~MD
    # Changelog

    Intro.

    ## [Unreleased]

    ### Added

    - A feature.

    ## [1.0.0] - 2026-11-03

    ### Added

    - The first release.

    [Unreleased]: #{REPO}/compare/v1.0.0...HEAD
    [1.0.0]: #{REPO}/releases/tag/v1.0.0
  MD

  LOCK_TEXT = <<~LOCK
    PATH
      remote: .
      specs:
        agentcat (1.0.0)
          agentcat-api (= 0.0.3)

    GEM
      specs:
        agentcat-api (0.0.3)

    CHECKSUMS
      agentcat (1.0.0)
      agentcat-api (0.0.3) sha256=abc
  LOCK

  def v(text)
    Release::Version.parse(text) || flunk("#{text.inspect} is not a version")
  end

  def test_versions_parse_only_as_major_minor_patch
    assert_equal "1.20.3", v("1.20.3").to_s
    assert_equal "0.0.0", v("0.0.0").to_s
    ["", "1", "1.2", "1.2.3.4", "01.2.3", "1.2.x", "v1.2.3", "1.2.3-rc.1", "1..3", "1.2.3\n"].each do |bad|
      assert_nil Release::Version.parse(bad), bad.inspect
    end
  end

  def test_the_newest_tag_ignores_tags_that_are_not_versions
    tags = %w[v1.0.0 v1.10.0 v1.9.9 attempt-1 v2.0 1.99.0]
    assert_equal v("1.10.0"), Release.newest_tag(tags)
    assert_nil Release.newest_tag(%w[attempt-1])
  end

  def test_words_count_from_the_newest_tag
    newest = v("1.2.3")
    assert_equal v("1.2.4"), Release.next_version("patch", newest, newest)
    assert_equal v("1.3.0"), Release.next_version("minor", newest, newest)
    assert_equal v("2.0.0"), Release.next_version("major", newest, newest)
    assert_equal v("1.5.0"), Release.next_version("1.5.0", newest, newest)
  end

  def test_an_exact_version_must_be_newer_than_the_newest_tag
    newest = v("1.2.3")
    error = assert_raises(Release::Error) { Release.next_version("1.2.3", newest, newest) }
    assert_equal "1.2.3 is not newer than the newest tag, v1.2.3", error.message
    assert_raises(Release::Error) { Release.next_version("1.0.9", newest, newest) }
    error = assert_raises(Release::Error) { Release.next_version("next", newest, newest) }
    assert_equal "\"next\" is not patch, minor, major or a version X.Y.Z", error.message
  end

  def test_the_first_release_is_the_version_of_version_rb
    %w[patch minor major 1.0.0].each do |word|
      assert_equal v("1.0.0"), Release.next_version(word, v("1.0.0"), nil), word
    end
    error = assert_raises(Release::Error) { Release.next_version("1.1.0", v("1.0.0"), nil) }
    assert_includes error.message, "the first release is the version of lib/agentcat/version.rb, 1.0.0"
    assert_raises(Release::Error) { Release.next_version("next", v("1.0.0"), nil) }
  end

  def test_the_version_file_and_the_lockfile_get_the_new_version
    text = "# typed: true\n\nmodule AgentCat\n  VERSION = \"1.0.0\"\nend\n"
    assert_equal v("1.0.0"), Release.file_version(text)
    assert_equal text.sub("1.0.0", "1.0.1"), Release.set_file_version(text, v("1.0.1"))
    assert_raises(Release::Error) { Release.set_file_version("module AgentCat\nend\n", v("1.0.1")) }

    # Both `agentcat (1.0.0)` lines change; `agentcat-api` keeps its version.
    assert_equal LOCK_TEXT.gsub("agentcat (1.0.0)", "agentcat (1.0.1)"), Release.set_lock_version(LOCK_TEXT, v("1.0.1"))
    assert_raises(Release::Error) { Release.set_lock_version("GEM\n  specs:\n", v("1.0.1")) }
  end

  def test_dating_moves_the_entries_under_the_version_and_links_both_sections
    dated = Release.date_changelog(CHANGELOG_TEXT, v("1.1.0"), "2026-12-01", v("1.0.0"))
    expected = CHANGELOG_TEXT
      .sub("## [Unreleased]\n", "## [Unreleased]\n\n## [1.1.0] - 2026-12-01\n")
      .sub("[Unreleased]: #{REPO}/compare/v1.0.0...HEAD\n",
        "[Unreleased]: #{REPO}/compare/v1.1.0...HEAD\n[1.1.0]: #{REPO}/compare/v1.0.0...v1.1.0\n")
    assert_equal expected, dated
    assert_equal ["2026-12-01", "### Added\n\n- A feature."], Release.dated_section(dated, v("1.1.0"))
  end

  def test_the_first_release_links_its_tag
    first = "## [Unreleased]\n\n- One.\n\n[Unreleased]: #{REPO}/commits/main\n"
    assert_equal <<~MD, Release.date_changelog(first, v("1.0.0"), "2026-11-03", nil)
      ## [Unreleased]

      ## [1.0.0] - 2026-11-03

      - One.

      [Unreleased]: #{REPO}/compare/v1.0.0...HEAD
      [1.0.0]: #{REPO}/releases/tag/v1.0.0
    MD
  end

  def test_dating_refuses_an_empty_section_a_bad_date_and_a_missing_section
    empty = "## [Unreleased]\n\n### Added\n\n## [1.0.0] - 2026-11-03\n\n- One.\n\n[Unreleased]: x\n"
    error = assert_raises(Release::Error) { Release.date_changelog(empty, v("1.0.1"), "2026-12-01", v("1.0.0")) }
    assert_includes error.message, "has no entry"
    assert_raises(Release::Error) { Release.date_changelog(CHANGELOG_TEXT, v("1.1.0"), "2026-12-1", nil) }
    assert_raises(Release::Error) { Release.date_changelog("# Changelog\n", v("1.1.0"), "2026-12-01", nil) }
    no_link = "## [Unreleased]\n\n- One.\n"
    error = assert_raises(Release::Error) { Release.date_changelog(no_link, v("1.0.0"), "2026-12-01", nil) }
    assert_includes error.message, "no [Unreleased] link"
  end

  def test_a_section_without_a_valid_date_is_not_dated
    assert_equal "2026-11-03", Release.dated_section(CHANGELOG_TEXT, v("1.0.0")).first
    assert_nil Release.dated_section("## [1.0.0] - soon\n- One.\n", v("1.0.0"))
    assert_nil Release.dated_section(CHANGELOG_TEXT, v("9.9.9"))
  end

  def test_main_rejects_unknown_arguments_with_the_usage
    code, text = Release.main(["publish"], ROOT)
    assert_equal 2, code
    assert text.start_with?("usage: "), text
  end

  # The three steps on a git repository, as the workflow runs them.
  def test_prepare_status_and_notes_on_a_repository
    in_repository(version: "1.0.0", changelog: CHANGELOG_TEXT, tags: %w[v1.0.0]) do |dir|
      assert_equal [0, "1.0.0 skip"], Release.main(["status"], dir)

      assert_equal [0, "1.0.1"], Release.main(["prepare", "patch", "2026-12-01"], dir)
      assert_equal v("1.0.1"), Release.file_version(File.read(File.join(dir, Release::VERSION_FILE)))
      assert_equal 2, File.read(File.join(dir, "Gemfile.lock")).scan("agentcat (1.0.1)").size
      assert_equal [0, "1.0.1 publish"], Release.main(["status"], dir)
      assert_equal [0, "### Added\n\n- A feature."], Release.main(["notes", "1.0.1"], dir)

      code, text = Release.main(["prepare", "patch", "2026-12-02"], dir)
      assert_equal 1, code
      assert_includes text, "has no entry"
    end
  end

  # The repository is staged for 1.0.0: no tag yet, version.rb holds 1.0.0, and the
  # [Unreleased] section has the entries of the release.
  def test_this_repository_prepares_1_0_0
    changelog = File.read(File.join(ROOT, Release::CHANGELOG))
    version = File.read(File.join(ROOT, Release::VERSION_FILE))
    in_repository(version: Release.file_version(version).to_s, changelog: changelog, tags: []) do |dir|
      assert_equal [0, "1.0.0"], Release.main(["prepare", "patch", "2026-11-10"], dir)
      assert_equal LOCK_TEXT, File.read(File.join(dir, "Gemfile.lock"))
      assert_equal [0, "1.0.0 publish"], Release.main(["status"], dir)

      code, notes = Release.main(["notes", "1.0.0"], dir)
      assert_equal 0, code
      assert_includes notes, "### Added"
      refute_includes notes, "## [0.0.1]"
      assert_includes File.read(File.join(dir, Release::CHANGELOG)), "[1.0.0]: #{REPO}/releases/tag/v1.0.0"
    end
  end

  private

  def in_repository(version:, changelog:, tags:)
    Dir.mktmpdir do |dir|
      FileUtils.mkdir_p(File.join(dir, "lib/agentcat"))
      File.write(File.join(dir, Release::VERSION_FILE), "module AgentCat\n  VERSION = \"#{version}\"\nend\n")
      File.write(File.join(dir, "Gemfile.lock"), LOCK_TEXT.gsub("agentcat (1.0.0)", "agentcat (#{version})"))
      File.write(File.join(dir, Release::CHANGELOG), changelog)
      git(dir, "init", "-q")
      git(dir, "-c", "user.name=t", "-c", "user.email=t@example.com", "commit", "-q", "--allow-empty", "-m", "start")
      tags.each { |tag| git(dir, "tag", tag) }
      yield dir
    end
  end

  def git(dir, *args)
    _out, error, status = Open3.capture3("git", *args, chdir: dir)
    assert status.success?, "git #{args.join(" ")}: #{error}"
  end
end
