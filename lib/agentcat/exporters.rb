# typed: true

require_relative "log"
require_relative "exporters/base"
require_relative "exporters/datadog"
require_relative "exporters/otlp"
require_relative "exporters/posthog"
require_relative "exporters/sentry"

module AgentCat
  # Optional telemetry forwarding, configured via Options#exporters. Runs on the
  # queue's worker thread so an exporter never blocks a tool call, and one raising
  # doesn't stop the rest from running.
  #
  # Works fine with project_id: nil — that's the case where you just want telemetry
  # forwarded somewhere and don't want AgentCat's own API involved at all.
  module Exporters
    extend T::Sig

    TYPES = T.let({"otlp" => Otlp, "datadog" => Datadog, "sentry" => Sentry, "posthog" => PostHog}.freeze, T::Hash[String, T.untyped])

    # Turns Options#exporters into exporter objects. An entry is an object responding
    # to #export(event) or #call(event), or TS's hash form,
    # `{type: "datadog", api_key: "..."}`: symbol or string keys, snake_case or TS's
    # camelCase (`apiKey`). An unknown type or a hash the exporter can't take logs one
    # ERROR line and is skipped; anything else logs one WARN line and is skipped.
    sig { params(entries: T::Array[T.untyped]).returns(T::Array[T.untyped]) }
    def self.resolve(entries)
      entries.each_with_index.filter_map do |entry, index|
        if entry.is_a?(Hash)
          from_hash(entry, index)
        elsif exporter?(entry)
          entry
        else
          Log.warn("Options#exporters[#{index}] must respond to #export or #call, or be a Hash with a type, got #{entry.class}; it is ignored")
          nil
        end
      end
    end

    # Anything responding to #export(event) or #call(event). event is fully redacted.
    sig { params(exporters: T::Array[T.untyped], event: UnredactedEvent).void }
    def self.dispatch(exporters, event)
      exporters.each do |exporter|
        dispatch_one(exporter, event)
      end
    end

    sig { params(entry: T.untyped).returns(T::Boolean) }
    def self.exporter?(entry)
      entry.respond_to?(:export) || entry.respond_to?(:call)
    end
    private_class_method :exporter?

    sig { params(hash: T::Hash[T.untyped, T.untyped], index: Integer).returns(T.untyped) }
    def self.from_hash(hash, index)
      config = hash.transform_keys(&:to_s)
      type = config.delete("type")
      klass = TYPES[type.to_s] if type.is_a?(String) || type.is_a?(Symbol)
      if klass.nil?
        shown = if type.is_a?(String) || type.is_a?(Symbol)
          type.to_s.inspect
        else
          (type.nil? ? "none" : type.class.to_s)
        end
        Log.error("Unknown exporter type: #{shown} in Options#exporters[#{index}] (expected #{TYPES.keys.join(", ")}); it is ignored")
        return nil
      end

      keywords = {}
      config.each do |key, value|
        name = klass.const_get(:CONFIG_KEYS)[key]
        if name
          keywords[name] = value
        else
          Log.warn("Unknown AgentCat option exporters[#{index}].#{key} ignored")
        end
      end
      klass.new(**keywords)
    rescue => e
      # A value of the wrong type fails the Sorbet sig. Its message can carry the value.
      Log.error("Failed to initialize exporter Options#exporters[#{index}] (#{type}) with #{e.class}; it is ignored")
      AgentCat.logger.debug { "exporter Options#exporters[#{index}] failed: #{e.class}: #{e.message}" }
      nil
    end
    private_class_method :from_hash

    sig { params(exporter: T.untyped, event: UnredactedEvent).void }
    def self.dispatch_one(exporter, event)
      method = if exporter.respond_to?(:export)
        :export
      elsif exporter.respond_to?(:call)
        :call
      end
      if method.nil?
        Log.warn("exporter #{exporter.class} does not respond to #export or #call; it is ignored")
        return
      end

      exporter.public_send(method, event)
    rescue => e
      # The message can carry the event or the vendor's response: debug only.
      Log.error("exporter #{exporter.class} failed with #{e.class}; the event was not exported")
      AgentCat.logger.debug { "exporter #{exporter.class} failed: #{e.class}: #{e.message}" }
    end
    private_class_method :dispatch_one
  end
end
