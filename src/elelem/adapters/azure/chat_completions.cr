require "../chat_completions"

module Elelem
  # Azure OpenAI speaks Chat Completions over the same wire shape as
  # `openai.chat_completions` — same `Profile`, same mapper, same exporter —
  # but is neither the same *server* nor the same *deployment* concern.
  # `api_version` is a required, dated query parameter Azure demands on every
  # call, which is why it lives here rather than in `Options`: it is a fact
  # about this deployment, not this request. See `Provider.for_azure`.
  #
  # Inherits `profile`, `error_detail` and `prepare` unchanged from
  # `ChatCompletionsAdapter` — path and headers are the only two facts Azure
  # actually amends. `max_tokens_field` is inherited too, not amended: which
  # spelling a deployment wants is a fact about the model behind it, not
  # about being Azure specifically. See `AzureResponsesAdapter` for the
  # sibling that amends the same protocol family differently — the two
  # disagree with each other on where the deployment goes, which is why
  # each is its own file rather than one class with a protocol switch.
  class AzureChatCompletionsAdapter < ChatCompletionsAdapter
    def initialize(@api_version : String, vendor : String? = nil,
                   reasoning_unit : Capability::ReasoningUnit? = nil,
                   max_tokens_field : Protocol::ChatCompletions::Wire::MaxTokensField = Protocol::ChatCompletions::Wire::MaxTokensField::MaxTokens)
      super(vendor, reasoning_unit, max_tokens_field)
    end

    # `model` here is the deployment name — Azure conflates the two, so no
    # separate parameter is needed. The deployment name still lands in the
    # request body too (`Protocol::ChatCompletions::Mapper` writes `model`
    # regardless); Azure ignores it there and only the path segment counts.
    def path(model : String) : String
      "/openai/deployments/#{URI.encode_path_segment(model)}/chat/completions?api-version=#{@api_version}"
    end

    def headers(credential : String?) : HTTP::Headers
      api_key(credential)
    end
  end
end
