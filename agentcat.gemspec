require_relative "lib/agentcat/version"

Gem::Specification.new do |s|
  s.name = "agentcat"
  s.version = AgentCat::VERSION
  s.summary = "AgentCat Ruby SDK for MCP servers"
  s.description = "Instruments MCP::Server tools with AgentCat session tracking, intent capture and event reporting."
  s.authors = ["AgentCat"]
  s.license = "MIT"
  # The repository moves to agentcathq later; these links resolve once it has.
  s.homepage = "https://github.com/agentcathq/agentcat-ruby-sdk"
  s.metadata = {
    "homepage_uri" => s.homepage,
    "source_code_uri" => "https://github.com/agentcathq/agentcat-ruby-sdk",
    "changelog_uri" => "https://github.com/agentcathq/agentcat-ruby-sdk/blob/main/CHANGELOG.md",
    "bug_tracker_uri" => "https://github.com/agentcathq/agentcat-ruby-sdk/issues",
    "rubygems_mfa_required" => "true"
  }
  s.required_ruby_version = ">= 3.3"
  s.files = Dir["lib/**/*.rb", "README.md", "LICENSE"]
  s.require_paths = ["lib"]

  # Hard-pinned, not `~>`: agentcat-api is the generated client modeling the wire contract,
  # so a patch bump is exactly the kind of change that shouldn't apply itself unreviewed on
  # a plain `bundle install`/`bundle update`. Bumping this is a deliberate step — see
  # CONTRIBUTING.md.
  s.add_runtime_dependency "agentcat-api", "= 0.0.3"
  s.add_runtime_dependency "sorbet-runtime", ">= 0.5"
  # The oldest `mcp` AgentCat supports, and the one place that floor lives: the `mcp compat`
  # workflow (scripts/mcp_versions.rb) reads it from here. Older releases are covered by the
  # DNS rebinding advisory GHSA-rjr6-rcgv-9m7m. Keep it a single `>=`.
  s.add_runtime_dependency "mcp", ">= 0.23.0"

  # minitest 6 moved `Object#stub` and `Minitest::Mock` into the separate minitest-mock gem.
  s.add_development_dependency "minitest", ">= 6"
  s.add_development_dependency "minitest-mock", ">= 5.27"
  # The `mcp` gem doesn't depend on rack, but its HTTP transport needs it, and the unit
  # tests run that transport. A real dev dependency, so `BUNDLE_WITHOUT=examples` still
  # runs the suite.
  s.add_development_dependency "rack", ">= 2.2"
  s.add_development_dependency "rake", ">= 13"
  # Line coverage for `COVERAGE=1 rake` (test/test_helper.rb); CI fails below the minimum.
  s.add_development_dependency "simplecov", ">= 0.22"
  s.add_development_dependency "sorbet", ">= 0.5"
  s.add_development_dependency "standard", ">= 1.35.1"
  # Not a gemspec dev dependency: tapioca pulls in a large tree (rbi, rbs, rubydex, spoom)
  # that only RBI generation needs. `srb tc` only consumes the checked-in RBIs, so tapioca
  # lives in the Gemfile's `:rbi` group instead. Every CI job sets `BUNDLE_WITHOUT=rbi` except one: ci.yml's
  # "type coverage & RBI freshness" job installs the group on Ruby 3.4 and runs
  # `tapioca gem --verify` (`rake rbi_freshness`), so a stale or missing gem RBI fails CI.
end
