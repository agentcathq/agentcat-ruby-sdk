# Contributing

## Setup

```bash
bundle install
```

## Tests

```bash
bundle exec rake
```

The suite runs against the official `mcp` gem: tools are defined with `MCP::Tool.define` and
exercised through `MCP::Server#handle`, so tests cover the same code path a real client uses.
Event publishing is tested against an in-process HTTP mock, no network access is needed.
The unit suite needs only the gemspec's development dependencies, so it also runs with
`BUNDLE_WITHOUT=rbi:examples`.

```bash
COVERAGE=1 bundle exec rake
```

Measures line coverage of `lib/` with SimpleCov (report in `coverage/`). CI runs the unit suite
this way, and the run fails when line coverage drops below 95% (`test/test_helper.rb`).

## End-to-end tests

```bash
bundle exec rake test:e2e
```

A separate, slower tier under `test/e2e/` — not run by the plain `rake`/`rake test` you'd use
in a local edit loop, but wired into CI as its own step (`.github/workflows/ci.yml`) so it
still runs on every push. Boots a real `MCP::Server` behind a
real Puma HTTP server on a random local port and drives it with genuine `Net::HTTP`
requests — the actual `mcp` gem dispatch and schema-validation stack in front of AgentCat,
not the `server.handle(hash)` shortcut the rest of the suite uses. Event *delivery* is still
faked (a `RecordingClient`, like the rest of the suite) — no real AgentCat credentials or
network access needed — but everything else in the request path is real. Delivery is
asynchronous, so the e2e recording client waits for the event queue to drain before it
returns `events` or `last_event`. This tier needs Puma from the Gemfile's `:examples` group. This tier exists
because the shortcut skips part of the `mcp` gem: its own required-argument
enforcement runs ahead of AgentCat's interceptor, and no in-process test sees that.

## Internals of the `mcp` gem

AgentCat uses some internals of the `mcp` gem: instance variables it reads, private methods
it overrides and public methods or hashes it patches. `lib/agentcat/private_members.rb`
(`AgentCat::PrivateMembers`) lists every one, with the feature that depends on it. When you
add a new use, or when a new `mcp` release changes one:

1. Add or change the `Member` constant (owner class, member name, kind, feature). Give a new
   feature a line in `FEATURES`; that text goes into the ERROR line when the member is missing.
2. Teach `PrivateMembers.probe` to check it on the loaded gem. Check an instance variable on a
   real instance, and a method's own definition (not a module that AgentCat prepends).
3. At the use site, name the member through its constant, never a literal. Check
   `PrivateMembers.enabled?(member.feature)` first, and call `PrivateMembers.missing!(member)`
   (then go on without the feature) if the member is gone at run time. Never raise into the host.
4. Run `bundle exec ruby -Itest test/test_private_members.rb`. It checks every member against
   the installed gem and fails with the member's name. The `mcp compat` workflow runs it on each
   `mcp` version in its matrix (`scripts/mcp_versions.rb` picks them from rubygems.org). To check
   another version locally, add `gem "mcp", "= x.y.z"` to the end of the `Gemfile` and run
   `bundle update mcp`.

If a release removes a member for good, keep the member (older versions still have it), and
add the new route next to it.

## Formatting

```bash
bundle exec standardrb
```

The SDK supports Ruby 3.3 and newer: the Ruby versions that still get security fixes
upstream (see https://www.ruby-lang.org/en/downloads/branches/). When a Ruby series reaches
its end of life, raise `required_ruby_version` in the gemspec, `.standard.yml` and the Ruby
lists in `ci.yml` and `mcp-compat.yml` together. The runtime dependencies are `agentcat-api`,
`sorbet-runtime` and the official `mcp` gem (`>= 0.23.0`).

`agentcat-api` is hard-pinned (`= x.y.z`), not `~>` — it's the generated client modeling the
wire contract, so bumping it is a deliberate, reviewed step: regenerate/vet the client
against the backend contract, then update the pin. Don't relax it back to `~>` later for
convenience.

## Record your change

Every change that a user can see adds an entry to the `[Unreleased]` section of `CHANGELOG.md`
in its pull request. The release notes come from this section.

## Release a version

The release workflow (`.github/workflows/release.yml`) does the release in two steps, with a pull
request between them. The Java and Rust SDKs release the same way.

1. In GitHub, open **Actions > Release > Run workflow** on `main`. Keep `patch`, or type `minor`,
   `major` or an exact version such as `1.2.0`. The words count from the newest `v*` tag. The
   first release has no tag yet: it is the version that `lib/agentcat/version.rb` holds (1.0.0).
2. The workflow opens the pull request "Release vX.Y.Z". It sets the version in
   `lib/agentcat/version.rb` and `Gemfile.lock`, and turns `[Unreleased]` into the dated section
   of the version. It also starts CI and `mcp compat` on the pull request. An `[Unreleased]`
   section with no entry, or a version that RubyGems already has, stops the workflow.
3. Read the pull request, and merge it when CI passes.
4. The merge starts the workflow again. It waits for CI on the merge commit and publishes the gem
   to RubyGems. Then it creates the tag `vX.Y.Z` and its GitHub release, with the CHANGELOG
   section as the notes.

If a step fails, fix the cause and re-run the failed jobs of that run. The publish step skips a
version that RubyGems already has, and the tag comes last.

Do not run `gem push` on your machine. RubyGems never accepts a version twice, not even a yanked
one, so a local push can use up a version for good. Only the release workflow publishes.

To run a step of the workflow by hand, use `ruby scripts/release.rb prepare <patch | minor |
major | X.Y.Z> <YYYY-MM-DD>`, `status` or `notes <X.Y.Z>`. `test/test_release.rb` tests these
steps in the normal suite.

The publish job uses RubyGems trusted publishing: RubyGems trades the OIDC token of the job for a
short-lived API key, so GitHub stores no RubyGems secret. The job also attests the build
provenance of the gem with Sigstore. To make sure that a gem came from this workflow, run
`gh attestation verify agentcat-X.Y.Z.gem -R agentcathq/agentcat-ruby-sdk`.

### One-time setup

- In the repository settings, turn on **Actions > General > Allow GitHub Actions to create and
  approve pull requests**, so that the workflow can open the release pull request.
- Create a `release` environment, limited to the `main` branch.
- On rubygems.org, a maintainer of `agentcat` adds a trusted publisher under **Trusted
  publishers** of the gem: the repository `agentcathq/agentcat-ruby-sdk`, the workflow
  `release.yml` and the environment `release`.
