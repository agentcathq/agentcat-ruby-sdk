# typed: true
# frozen_string_literal: true

# Add your extra requires here (`bin/tapioca require` can be used to bootstrap this list)

# `examples/http_server.rb` requires this directly (it's how `Rackup::Handler.get("puma")`
# would resolve it too) — the plain `puma` require alone never defines `Rackup::Handler::Puma`.
require "rack/handler/puma"
