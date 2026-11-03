require_relative "test_helper"

# The gem page on rubygems.org links to the repository under agentcathq.
class GemspecTest < Minitest::Test
  REPO = "https://github.com/agentcathq/agentcat-ruby-sdk"

  def spec
    @spec ||= Gem::Specification.load(File.expand_path("../agentcat.gemspec", __dir__))
  end

  def test_links_point_at_agentcat_and_the_agentcathq_repository
    assert_equal "https://agentcat.com", spec.homepage
    assert_equal REPO, spec.metadata["source_code_uri"]
    assert_equal "#{REPO}/blob/main/CHANGELOG.md", spec.metadata["changelog_uri"]
    assert_equal "#{REPO}/issues", spec.metadata["bug_tracker_uri"]
  end

  def test_requires_mfa_to_push
    assert_equal "true", spec.metadata["rubygems_mfa_required"]
  end

  def test_readme_images_use_absolute_urls
    readme = File.read(File.expand_path("../README.md", __dir__))
    sources = readme.scan(/<img[^>]*\ssrc="([^"]+)"/).flatten

    relative = sources.reject { |src| src.start_with?("https://") }
    assert_empty relative, "README images must use absolute URLs to render on rubygems.org"
    %w[docs/static/og-image.png docs/static/architecture.png docs/cats/bibi.png docs/cats/zelda.jpg docs/cats/void.jpg].each do |path|
      assert_includes sources, "https://raw.githubusercontent.com/agentcathq/agentcat-ruby-sdk/main/#{path}"
      assert File.exist?(File.expand_path("../#{path}", __dir__)), "#{path} is missing"
    end
  end
end
