# Picks the `mcp` gem versions the `mcp compat` workflow tests.
#
#   ruby scripts/mcp_versions.rb 3.3 3.4 4.0
#   ruby scripts/mcp_versions.rb --file versions.json 3.1 3.3 3.4
#
# Reads every release from rubygems.org at run time (or from --file), keeps the stable
# X.Y.Z versions at or above the floor, and takes the floor plus the newest patch of every
# minor. The floor is the `mcp` runtime dependency in agentcat.gemspec, its only home.
# Prints a GitHub Actions matrix, `{"include": [{"mcp": "1.8.2", "ruby": "3.3"}, ...]}`,
# with one row per version and Ruby. A row is left out when the version's `ruby_version`
# (from the same API) rejects that Ruby; the excluded pairs go to stderr.
require "json"
require "net/http"
require "rubygems"

module McpVersions
  URL = "https://rubygems.org/api/v1/versions/mcp.json"
  GEMSPEC = File.expand_path("../agentcat.gemspec", __dir__)
  STABLE = /\A\d+\.\d+\.\d+\z/

  class Error < StandardError; end

  Release = Struct.new(:number, :ruby_version) do
    def version
      Gem::Version.new(number)
    end

    def minor
      version.segments.first(2)
    end

    # setup-ruby installs the newest patch of a "3.3"-style Ruby, so compare against a
    # patch above any real one: ">= 3.3.4" runs on "3.3", ">= 3.4.0" and "< 3.3" do not.
    def supports?(ruby)
      return true if ruby_version.nil? || ruby_version.strip.empty?

      Gem::Requirement.new(*ruby_version.split(",")).satisfied_by?(Gem::Version.new("#{ruby}.999"))
    end
  end

  module_function

  def floor(gemspec_path = GEMSPEC)
    floor_of(Gem::Specification.load(gemspec_path) || raise(Error, "cannot load #{gemspec_path}"))
  end

  # The floor is the single `>= X.Y.Z` of the gemspec's runtime `mcp` dependency.
  def floor_of(spec)
    dependency = spec.runtime_dependencies.find { |dep| dep.name == "mcp" }
    raise Error, "agentcat.gemspec has no runtime dependency on mcp" unless dependency

    requirements = dependency.requirement.requirements
    operator, version = requirements.first
    unless requirements.size == 1 && operator == ">="
      raise Error, "the mcp dependency must be one `>= X.Y.Z`, not `#{dependency.requirement}`"
    end

    version.to_s
  end

  def pick(entries, floor:)
    floor_version = Gem::Version.new(floor)
    stable = entries
      .select { |entry| !entry["prerelease"] && entry.fetch("platform", "ruby") == "ruby" }
      .select { |entry| STABLE.match?(entry["number"]) }
      .map { |entry| Release.new(entry["number"], entry["ruby_version"]) }
      .select { |release| release.version >= floor_version }
      .uniq(&:number)

    floor_release = stable.find { |release| release.version == floor_version }
    raise Error, "mcp #{floor} (the floor) is not a stable release on rubygems.org" unless floor_release

    newest = stable.group_by(&:minor).values.map { |releases| releases.max_by(&:version) }
    [floor_release, *newest].uniq(&:number).sort_by(&:version)
  end

  def matrix(entries, floor:, rubies:, excluded: [])
    pick(entries, floor: floor).flat_map do |release|
      rubies.filter_map do |ruby|
        next {"mcp" => release.number, "ruby" => ruby} if release.supports?(ruby)

        excluded << "mcp #{release.number} on Ruby #{ruby} (needs Ruby #{release.ruby_version})"
        nil
      end
    end
  end

  def fetch(url = URL)
    response = Net::HTTP.get_response(URI(url))
    raise Error, "GET #{url} returned #{response.code}" unless response.is_a?(Net::HTTPSuccess)

    JSON.parse(response.body)
  end

  def main(argv)
    file = (index = argv.index("--file")) ? argv.slice!(index, 2).last : nil
    rubies = argv
    raise Error, "usage: mcp_versions.rb [--file versions.json] RUBY..." if rubies.empty?

    entries = file ? JSON.parse(File.read(file)) : fetch
    excluded = []
    rows = matrix(entries, floor: floor, rubies: rubies, excluded: excluded)
    excluded.each { |line| warn "skipped: #{line}" }
    JSON.generate({"include" => rows})
  end
end

if $PROGRAM_NAME == __FILE__
  begin
    puts McpVersions.main(ARGV.dup)
  rescue McpVersions::Error, JSON::ParserError, SystemCallError, Net::OpenTimeout, Net::ReadTimeout => e
    abort "mcp_versions: #{e.message}"
  end
end
