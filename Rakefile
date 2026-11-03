require "rake/testtask"

Rake::TestTask.new do |t|
  t.libs << "test"
  t.test_files = FileList["test/**/test_*.rb"].exclude("test/e2e/**/*")
end

desc "End-to-end tests against a real MCP::Server over real HTTP (separate tier: slower, " \
  "not run by `rake`/`rake test` by default — see test/e2e/README.md)"
Rake::TestTask.new("test:e2e") do |t|
  t.libs << "test"
  t.pattern = "test/e2e/**/test_*.rb"
end

desc "Typecheck with Sorbet"
task :sorbet do
  sh "bundle exec srb tc"
end

# Tracks each lib/ file's `# typed:` sigil against sorbet/sigil_baseline.txt so a sigil
# can't quietly drop from strict/true back to a looser level in a routine PR. Improving
# a file's sigil needs no action here; only a regression fails the check. New or removed
# files must be re-baselined explicitly (`rake type_coverage:update`), so they can't slip
# through unrecorded either.
SIGIL_BASELINE_PATH = "sorbet/sigil_baseline.txt"
SIGIL_RANK = {"ignore" => 0, "false" => 1, "true" => 2, "strict" => 3, "strong" => 4}.freeze

def lib_sigils
  Dir.glob("lib/**/*.rb").sort.each_with_object({}) do |path, acc|
    first_line = File.foreach(path).first
    match = first_line&.match(/\A#\s*typed:\s*(\w+)/)
    raise "#{path} is missing a `# typed:` sigil" unless match

    acc[path] = match[1]
  end
end

desc "Check lib/ Sorbet sigils haven't regressed against #{SIGIL_BASELINE_PATH}"
task :type_coverage do
  current = lib_sigils
  baseline = File.readlines(SIGIL_BASELINE_PATH, chomp: true).reject(&:empty?).to_h { |line| line.split(":", 2) }

  problems = []

  added = current.keys - baseline.keys
  problems << "new file(s) not in #{SIGIL_BASELINE_PATH} — run `rake type_coverage:update`: #{added.join(", ")}" if added.any?

  removed = baseline.keys - current.keys
  problems << "#{SIGIL_BASELINE_PATH} references removed file(s) — run `rake type_coverage:update`: #{removed.join(", ")}" if removed.any?

  current.each do |path, sigil|
    next unless baseline[path]
    next if SIGIL_RANK.fetch(sigil) >= SIGIL_RANK.fetch(baseline[path])

    problems << "#{path} regressed from `#{baseline[path]}` to `#{sigil}`"
  end

  abort(problems.join("\n")) if problems.any?

  puts "type coverage: #{current.size} files checked against #{SIGIL_BASELINE_PATH}, no regressions"
end

namespace :type_coverage do
  desc "Regenerate #{SIGIL_BASELINE_PATH} from the current lib/ sigils"
  task :update do
    File.write(SIGIL_BASELINE_PATH, lib_sigils.map { |path, sigil| "#{path}:#{sigil}\n" }.join)
    puts "wrote #{SIGIL_BASELINE_PATH}"
  end
end

desc "Verify checked-in Sorbet RBIs for gems match the Gemfile.lock"
task :rbi_freshness do
  sh "bundle exec tapioca gem --verify"
end

task default: :test
