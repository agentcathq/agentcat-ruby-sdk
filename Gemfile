source "https://rubygems.org"

gemspec

group :examples do
  gem "puma", ">= 6"
  gem "rackup", ">= 2"
end

# Kept out of the implicit gemspec :development group on purpose — see the comment in
# agentcat.gemspec. `bundle exec tapioca gem ...` needs this group
# installed locally. CI skips it with `BUNDLE_WITHOUT=rbi`, except the
# job that runs `rake rbi_freshness`.
group :rbi do
  gem "tapioca", ">= 0.11"
end
