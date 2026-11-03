# typed: true

require "json"

module AgentCat
  # Wraps a tool registered on an MCP server.
  #
  # Exposes the same surface `MCP::Tool` does (`name_value`, `input_schema`, `title`,
  # `annotations`, `to_h`, `call`, ...), so `MCP::Server` can list, validate and dispatch
  # it with no idea it's wrapped.
  class ToolHandle
    extend T::Sig

    sig { returns(String) }
    attr_reader :name

    sig { returns(T.nilable(String)) }
    attr_reader :title

    sig { returns(T.nilable(String)) }
    attr_reader :description

    sig { returns(T.untyped) }
    attr_reader :icons

    sig { returns(T.untyped) }
    attr_reader :annotations

    sig { returns(T.untyped) }
    attr_reader :meta

    sig { returns(T.untyped) }
    attr_reader :input_schema

    sig { returns(T.untyped) }
    attr_reader :output_schema

    alias_method :name_value, :name
    alias_method :title_value, :title
    alias_method :description_value, :description
    alias_method :icons_value, :icons
    alias_method :annotations_value, :annotations
    alias_method :meta_value, :meta
    alias_method :input_schema_value, :input_schema
    alias_method :output_schema_value, :output_schema

    # `call_fn` receives `(arguments, server_context)` where `arguments` is a string-keyed Hash.
    sig do
      params(
        name: String,
        call_fn: T.untyped,
        input_schema: T.untyped,
        output_schema: T.untyped,
        title: T.nilable(String),
        description: T.nilable(String),
        icons: T.untyped,
        annotations: T.untyped,
        meta: T.untyped
      ).void
    end
    def initialize(name:, call_fn:, input_schema: nil, output_schema: nil, title: nil, description: nil, icons: nil, annotations: nil, meta: nil)
      @name = name
      @call_fn = call_fn
      @input_schema = input_schema || {type: "object", properties: {}}
      @output_schema = output_schema
      @title = title
      @description = description
      @icons = icons
      @annotations = annotations
      @meta = meta
      @interceptor = T.let(nil, T.untyped)
      @soft_required = T.let({}, T::Hash[String, String])
    end

    sig { returns(T::Hash[Symbol, T.untyped]) }
    def to_h
      {
        name: name,
        title: title,
        description: description,
        icons: icons_to_h,
        inputSchema: schema_to_h(input_schema),
        outputSchema: schema_to_h(output_schema),
        annotations: annotations&.to_h,
        _meta: meta
      }.compact
    end

    # Whether the input schema is a `oneOf`/`allOf`/`anyOf` composition rather than a
    # plain object schema. `properties`/`required` have no defined meaning as a sibling
    # of these keywords, so injecting into one would either do nothing or corrupt it -
    # safer to leave composed schemas alone entirely.
    sig { returns(T::Boolean) }
    def composed_input_schema?
      composed?(schema_to_h(input_schema))
    end

    sig { returns(T::Boolean) }
    def composed_output_schema?
      composed?(schema_to_h(output_schema))
    end

    # Adds a string property to the input schema, optionally `required` and/or with a
    # `pattern`, unless that name is already there. Keeps the schema's original class
    # (Hash stays Hash, `MCP::Tool::InputSchema` gets rebuilt). Safe to call twice. No-op
    # on a composed schema - see `composed_input_schema?`.
    #
    # `required` here is soft, like the TS SDK's: `tools/list` shows the name under
    # `required` so schema-aware clients fill it in, but a call that leaves it out still
    # gets through to the interceptor instead of being bounced by the `mcp` gem's own
    # required check (see `SoftRequired`). `placeholder` is what that check is handed in
    # place of a missing value - it never reaches the handler or the event.
    sig { params(name: T.any(String, Symbol), description: T.nilable(String), type: String, required: T::Boolean, pattern: T.nilable(String), placeholder: String).returns(T.self_type) }
    def add_input_parameter(name, description: nil, type: "string", required: false, pattern: nil, placeholder: "")
      return self if composed_input_schema?

      key = name.to_sym
      schema = T.must(schema_to_h(input_schema))
      properties = (schema[:properties] ||= {})
      declared = properties.key?(key)
      properties[key] = {type: type, description: description, pattern: pattern}.compact unless declared

      # Without the gem internals that make it soft (`PrivateMembers`), a required name
      # would turn away every call that leaves it out, so it is only listed, not required.
      required = false if required && !declared && !soft_required_supported?
      if required
        required_list = T.let(schema[:required] ||= [], T::Array[T.untyped])
        required_list << key.to_s unless required_list.include?(key.to_s)
        # Only soften what we added - a name the tool declared itself stays as strict as
        # the tool made it (our own `get_more_tools` declares its `context`).
        @soft_required[key.to_s] = placeholder unless declared
      end

      @input_schema = rebuild_input_schema(input_schema, schema)
      self
    end

    # Adds a property to the output schema unless one with that name exists, the tool
    # declares no output schema at all (nothing to extend), or that schema is composed -
    # see `composed_output_schema?`. `schema` is a full JSON Schema property hash (type,
    # description, nested properties, ...).
    sig { params(name: T.any(String, Symbol), schema: T::Hash[Symbol, T.untyped]).returns(T.self_type) }
    def add_output_parameter(name, schema)
      return self if output_schema.nil? || composed_output_schema?

      key = name.to_sym
      hash = T.must(schema_to_h(output_schema))
      properties = (hash[:properties] ||= {})
      return self if properties.key?(key)

      properties[key] = schema
      @output_schema = rebuild_schema(output_schema, hash)
      self
    end

    sig { params(name: T.any(String, Symbol)).returns(T::Boolean) }
    def input_parameter?(name)
      properties = T.must(schema_to_h(input_schema))[:properties] || {}
      properties.key?(name.to_sym)
    end

    sig { params(interceptor: T.untyped).returns(T.self_type) }
    def intercept(&interceptor)
      @interceptor = interceptor
      self
    end

    sig { returns(T::Boolean) }
    def intercepted?
      !@interceptor.nil?
    end

    # Entry point used by `MCP::Server` (`tool.call(**arguments, server_context: ctx)`).
    # A positional Hash is accepted for direct invocation.
    sig { params(arguments: T.nilable(T::Hash[T.untyped, T.untyped]), server_context: T.untyped, keyword_arguments: T.untyped).returns(T.untyped).checked(:tests) }
    def call(arguments = nil, server_context: nil, **keyword_arguments)
      arguments = keyword_arguments if arguments.nil?
      return invoke_original(arguments, server_context) unless @interceptor

      @interceptor.call(arguments, server_context, method(:invoke_original))
    end

    sig { params(arguments: T.nilable(T::Hash[T.untyped, T.untyped]), server_context: T.untyped).returns(T.untyped).checked(:tests) }
    def invoke_original(arguments, server_context)
      @call_fn.call((arguments || {}).transform_keys(&:to_s), server_context)
    end

    private

    sig { returns(T::Boolean) }
    def soft_required_supported?
      input_schema.is_a?(Hash) || PrivateMembers.enabled?(PrivateMembers::INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS.feature)
    end

    sig { returns(T.nilable(T::Array[T.untyped])) }
    def icons_to_h
      return nil if icons.nil? || icons.empty?

      icons.map { |icon| icon.respond_to?(:to_h) ? icon.to_h : icon }
    end

    # Deep copy of a schema as a symbol-keyed Hash.
    sig { params(schema: T.untyped).returns(T.nilable(T::Hash[Symbol, T.untyped])) }
    def schema_to_h(schema)
      return nil if schema.nil?

      hash = schema.is_a?(Hash) ? schema : schema.to_h
      JSON.parse(JSON.generate(hash), symbolize_names: true)
    end

    sig { params(schema: T.nilable(T::Hash[Symbol, T.untyped])).returns(T::Boolean) }
    def composed?(schema)
      !!(schema && (schema.key?(:oneOf) || schema.key?(:allOf) || schema.key?(:anyOf)))
    end

    # Same as `rebuild_schema`, but an `MCP::Tool::InputSchema` comes back soft about the
    # names in `@soft_required`. A plain Hash can't carry that, so it stays as it is.
    sig { params(original: T.untyped, hash: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
    def rebuild_input_schema(original, hash)
      return hash if original.is_a?(Hash)
      return rebuild_schema(original, hash) if @soft_required.empty? || !original.respond_to?(:missing_required_arguments)

      SoftRequired.build(original.class, hash, @soft_required)
    end

    # Hash stays Hash; anything else (`MCP::Tool::InputSchema`/`OutputSchema`) gets
    # reconstructed from the mutated hash so the original wrapper class survives.
    sig { params(original: T.untyped, hash: T::Hash[Symbol, T.untyped]).returns(T.untyped) }
    def rebuild_schema(original, hash)
      original.is_a?(Hash) ? hash : original.class.new(hash)
    end
  end

  # Makes some `required` names advisory on an `MCP::Tool::InputSchema`, by overriding two
  # of its methods (`PrivateMembers::INPUT_SCHEMA_*`). `to_h` (what
  # `tools/list` sends) is untouched, so those names still show as required. The two
  # checks the `mcp` gem runs before calling a tool skip them: `missing_required_arguments`
  # leaves them out, and `validate_arguments` (only on with `validate_tool_call_arguments`)
  # validates as if the missing ones had their placeholder. The arguments themselves
  # aren't touched, so the interceptor sees exactly what the agent sent.
  module SoftRequired
    extend T::Sig

    SUBCLASSES = T.let({}, T::Hash[T.untyped, T.untyped])
    SUBCLASSES_MUTEX = T.let(Mutex.new, Mutex)

    sig { params(base: T.untyped, hash: T::Hash[Symbol, T.untyped], placeholders: T::Hash[String, String]).returns(T.untyped) }
    def self.build(base, hash, placeholders)
      schema = class_for(base).new(hash)
      schema.soft_placeholders = placeholders.dup.freeze
      schema
    end

    # One subclass per schema class, made on first use — `mcp` may not even be loaded
    # when agentcat is. A schema that's already soft keeps its class.
    sig { params(base: T.untyped).returns(T.untyped) }
    def self.class_for(base)
      return base if base < SchemaMethods

      SUBCLASSES_MUTEX.synchronize do
        SUBCLASSES[base] ||= Class.new(base) { include SchemaMethods }
      end
    end

    module SchemaMethods
      attr_accessor :soft_placeholders

      def missing_required_arguments(arguments)
        super - soft_placeholders.keys
      rescue NoMethodError => e
        Kernel.raise unless e.name == :missing_required_arguments && e.receiver.equal?(self)

        AgentCat::PrivateMembers.missing!(AgentCat::PrivateMembers::INPUT_SCHEMA_MISSING_REQUIRED_ARGUMENTS)
        []
      end

      def validate_arguments(arguments)
        given = arguments.keys.map(&:to_s)
        filler = soft_placeholders.except(*given).transform_keys(&:to_sym)
        super(filler.merge(arguments))
      rescue NoMethodError => e
        Kernel.raise unless e.name == :validate_arguments && e.receiver.equal?(self)

        AgentCat::PrivateMembers.missing!(AgentCat::PrivateMembers::INPUT_SCHEMA_VALIDATE_ARGUMENTS)
        nil
      end
    end
  end
end
