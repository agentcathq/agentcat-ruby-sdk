# typed: true

# Hand-written shims for the OpenTelemetry API the Otlp exporter touches when you
# pass your own tracer:. tapioca cannot generate these — the gem is not installed
# here — so keep them minimal and untyped.

module OpenTelemetry
  module Trace
    module SpanKind
      SERVER = T.unsafe(nil)
    end

    module Status
      def self.error(message = nil); end
    end
  end
end
