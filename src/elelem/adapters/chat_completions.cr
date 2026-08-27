require "./adapter"
require "../protocol/chat_completions/mapper"
require "../protocol/chat_completions/export"

module Elelem
  class ChatCompletionsAdapter < Adapter
    # Which spelling of the output cap this deployment wants. See
    # `Protocol::ChatCompletions::Wire::MaxTokensField` for why this defaults
    # to the old spelling everywhere rather than the new one anywhere.
    getter max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField

    def initialize(vendor : String? = nil, reasoning_unit : Capability::ReasoningUnit? = nil,
                   @max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField = Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens)
      super(vendor, reasoning_unit)
    end

    def profile : Capability::Profile
      Protocol::ChatCompletions::PROFILE
    end

    def path(model : String) : String
      "/v1/chat/completions"
    end

    def headers(credential : String?) : HTTP::Headers
      bearer(credential)
    end

    def error_detail(body : String) : String?
      nested_error(body)
    end

    def prepare(session : MPSH::Session, model : String, policy : Capability::Policy,
                retention : Capability::ReasoningRetention, max_tokens : Int32,
                options : Options = Options.new) : Exchange
      mapper = Protocol::ChatCompletions::Mapper.new(narrowed(model), max_tokens_field: @max_tokens_field)
      request, report = mapper.map(session, model, policy, retention, options)
      exporter = Protocol::ChatCompletions::Exporter.new(mapper.calls)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end
  end
end
