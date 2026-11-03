# The release steps of .github/workflows/release.yml, on lib/agentcat/version.rb,
# Gemfile.lock, CHANGELOG.md and the `v*` tags of the repository. The Java SDK
# (scripts/Release.java) and the Rust SDK (xtask release) have the same three steps.
#
#   ruby scripts/release.rb prepare <patch | minor | major | X.Y.Z> <YYYY-MM-DD>
#   ruby scripts/release.rb status
#   ruby scripts/release.rb notes <X.Y.Z>
#
# - `prepare` picks the next version, writes it into version.rb and Gemfile.lock, turns the
#   [Unreleased] section of the CHANGELOG into the section of that version with the date, and
#   prints the version. `patch`, `minor` and `major` count from the newest `v*` tag. With no
#   tag yet, the first release is the version that version.rb holds, whatever the input word.
#   An exact version must be newer than the newest tag. An [Unreleased] section with no entry
#   stops the step: a release needs a change.
# - `status` prints `<version> publish` when the version of version.rb has no tag and the
#   CHANGELOG has its dated section, else `<version> skip`.
# - `notes` prints the body of the CHANGELOG section of that version.
require "open3"

module Release
  REPOSITORY = "https://github.com/agentcathq/agentcat-ruby-sdk"
  VERSION_FILE = "lib/agentcat/version.rb"
  LOCKFILE = "Gemfile.lock"
  CHANGELOG = "CHANGELOG.md"
  UNRELEASED = "## [Unreleased]"
  USAGE = "usage: ruby scripts/release.rb prepare <patch | minor | major | X.Y.Z> <YYYY-MM-DD> | status | notes <X.Y.Z>"

  # MAJOR.MINOR.PATCH with decimal numbers and no leading zero: no pre-release or build part.
  VERSION_PATTERN = /\A(0|[1-9]\d*)\.(0|[1-9]\d*)\.(0|[1-9]\d*)\z/
  DATE_PATTERN = /\A\d{4}-\d{2}-\d{2}\z/
  VERSION_LINE = /^(\s*VERSION = ")([^"]*)(")$/
  # The `agentcat (X.Y.Z)` lines of the PATH specs and the CHECKSUMS; not `agentcat-api`.
  LOCK_LINE = /^(\s+agentcat \()(\d+\.\d+\.\d+)(\))$/

  class Error < StandardError; end

  Version = Struct.new(:major, :minor, :patch) do
    include Comparable

    def self.parse(text)
      match = VERSION_PATTERN.match(text.to_s)
      match && new(*match.captures.map(&:to_i))
    end

    def <=>(other)
      to_a <=> other.to_a
    end

    def to_s
      to_a.join(".")
    end
  end

  module_function

  # The newest of the `v<version>` tags; other tags do not count.
  def newest_tag(tags)
    tags.filter_map { |tag| tag.start_with?("v") && Version.parse(tag[1..]) }.max
  end

  # The version of the release that `input` asks for: see the comment at the top.
  def next_version(input, current, newest)
    if newest.nil?
      exact = Version.parse(input)
      if exact && exact != current
        raise Error, "the first release is the version of #{VERSION_FILE}, #{current}; set it there to release #{exact}"
      end
      return current if exact || %w[patch minor major].include?(input)

      raise Error, "#{input.inspect} is not patch, minor, major or a version X.Y.Z"
    end

    following =
      case input
      when "patch" then Version.new(newest.major, newest.minor, newest.patch + 1)
      when "minor" then Version.new(newest.major, newest.minor + 1, 0)
      when "major" then Version.new(newest.major + 1, 0, 0)
      else Version.parse(input) || raise(Error, "#{input.inspect} is not patch, minor, major or a version X.Y.Z")
      end
    raise Error, "#{following} is not newer than the newest tag, v#{newest}" unless following > newest

    following
  end

  def file_version(text)
    match = VERSION_LINE.match(text)
    match && Version.parse(match[2])
  end

  def set_file_version(text, version)
    raise Error, "#{VERSION_FILE} has no VERSION line" unless VERSION_LINE.match?(text)

    text.sub(VERSION_LINE) { "#{$1}#{version}#{$3}" }
  end

  def set_lock_version(text, version)
    raise Error, "#{LOCKFILE} has no `agentcat (X.Y.Z)` line" unless LOCK_LINE.match?(text)

    text.gsub(LOCK_LINE) { "#{$1}#{version}#{$3}" }
  end

  # `changelog` with its [Unreleased] entries moved under `## [<version>] - <date>`, an empty
  # [Unreleased] section above it, and the links of both sections.
  def date_changelog(changelog, version, date, previous)
    raise Error, "#{date.inspect} is not a date YYYY-MM-DD" unless DATE_PATTERN.match?(date)

    lines = changelog.lines(chomp: true)
    start = lines.index(UNRELEASED) || raise(Error, "#{CHANGELOG} has no #{UNRELEASED} section")
    unless lines[(start + 1)...section_end(lines, start)].any? { |line| line.start_with?("- ") }
      raise Error, "the #{UNRELEASED} section of #{CHANGELOG} has no entry; add the changes of the release first"
    end

    link = lines.index { |line| line.start_with?("[Unreleased]: ") } ||
      raise(Error, "#{CHANGELOG} has no [Unreleased] link")
    version_link =
      if previous
        "[#{version}]: #{REPOSITORY}/compare/v#{previous}...v#{version}"
      else
        "[#{version}]: #{REPOSITORY}/releases/tag/v#{version}"
      end

    out = lines.each_with_index.flat_map do |line, index|
      if index == start
        [UNRELEASED, "", "## [#{version}] - #{date}"]
      elsif index == link
        ["[Unreleased]: #{REPOSITORY}/compare/v#{version}...HEAD", version_link]
      else
        [line]
      end
    end
    out.join("\n") + "\n"
  end

  # The date and the body of the `## [<version>] - <date>` section, without its blank edges.
  def dated_section(changelog, version)
    lines = changelog.lines(chomp: true)
    heading = "## [#{version}] - "
    start = lines.index { |line| line.start_with?(heading) }
    return nil unless start

    date = lines[start].delete_prefix(heading).strip
    return nil unless DATE_PATTERN.match?(date)

    body = lines[(start + 1)...section_end(lines, start)].join("\n")
    [date, body.gsub(/\A\n+|\n+\z/, "")]
  end

  # The index of the line after the section that starts at `start`: the next `## ` heading or
  # the first link line.
  def section_end(lines, start)
    offset = lines[(start + 1)..].index { |line| line.start_with?("## ") || line.match?(/\A\[[^\]]+\]: /) }
    offset ? start + 1 + offset : lines.size
  end

  def prepare(root, input, date)
    text = read(root, VERSION_FILE)
    current = file_version(text) || raise(Error, "#{VERSION_FILE} has no valid version")
    newest = newest_tag(tags(root))
    version = next_version(input, current, newest)
    changelog = date_changelog(read(root, CHANGELOG), version, date, newest)
    if version != current
      write(root, VERSION_FILE, set_file_version(text, version))
      write(root, LOCKFILE, set_lock_version(read(root, LOCKFILE), version))
    end
    write(root, CHANGELOG, changelog)
    version.to_s
  end

  def status(root)
    version = file_version(read(root, VERSION_FILE)) || raise(Error, "#{VERSION_FILE} has no valid version")
    tagged = tags(root).include?("v#{version}")
    dated = !dated_section(read(root, CHANGELOG), version).nil?
    "#{version} #{(!tagged && dated) ? "publish" : "skip"}"
  end

  def notes(root, text)
    version = Version.parse(text) || raise(Error, "#{text.inspect} is not a version X.Y.Z")
    section = dated_section(read(root, CHANGELOG), version) ||
      raise(Error, "#{CHANGELOG} has no dated section for #{version}")
    section.last
  end

  def tags(root)
    output, error, status = Open3.capture3("git", "tag", "--list", chdir: root)
    raise Error, "git tag --list failed: #{error.strip}" unless status.success?

    output.lines(chomp: true)
  rescue SystemCallError => e
    raise Error, "cannot run git: #{e.message}"
  end

  def read(root, path)
    File.read(File.join(root, path))
  rescue SystemCallError => e
    raise Error, "cannot read #{path}: #{e.message}"
  end

  def write(root, path, text)
    File.write(File.join(root, path), text)
  rescue SystemCallError => e
    raise Error, "cannot write #{path}: #{e.message}"
  end

  # Returns the exit code and the text for stdout or stderr.
  def main(argv, root = File.expand_path("..", __dir__))
    output =
      case argv
      in ["prepare", input, date] then prepare(root, input, date)
      in ["status"] then status(root)
      in ["notes", version] then notes(root, version)
      else return [2, USAGE]
      end
    [0, output]
  rescue Error => e
    [1, "release: #{e.message}"]
  end
end

if $PROGRAM_NAME == __FILE__
  code, text = Release.main(ARGV.dup)
  (code == 0) ? puts(text) : warn(text)
  exit code
end
