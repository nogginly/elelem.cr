module Elelem::MPSH
  # A real variant type, deliberately *not* `JSON::Any`.
  #
  # `JSON::Any` is a parse artifact: it carries the assumption that the value
  # came off a wire, and it forces every consumer to re-inspect and re-cast.
  # `Value` is the same shape with none of that history, and it is what lets
  # `provider_metadata` and tool-call arguments be structured without dragging
  # a serialization identity into the canonical types.
  alias Value = Nil | Bool | Int64 | Float64 | String | Array(Value) | Hash(String, Value)

  # Structured object, e.g. tool-call arguments.
  alias Object = Hash(String, Value)

  # Provider-namespaced side data: `{"openai" => {...}, "anthropic" => {...}}`.
  #
  # The namespacing *is* the drop logic. A mapper reads only its own key, so
  # foreign provider data is left behind without anyone writing (or forgetting)
  # an explicit discard step.
  alias Metadata = Hash(String, Object)

  # Mixed into every block and into `Message`.
  module ProviderScoped
    getter provider_metadata : Metadata { Metadata.new }
    setter provider_metadata

    # Everything the named provider needs echoed back, or nil.
    def meta_for(provider : String) : Object?
      @provider_metadata.try &.[provider]?
    end

    def put_meta(provider : String, key : String, value : Value) : Nil
      (provider_metadata[provider] ||= Object.new)[key] = value
    end

    def meta?(provider : String, key : String) : Value?
      meta_for(provider).try &.[key]?
    end
  end
end
