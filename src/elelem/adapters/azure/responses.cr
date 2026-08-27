require "../responses"

module Elelem
  # Azure OpenAI's Responses surface, same wire shape as
  # `openai.responses` — nothing about the mapper or exporter changes here
  # either, only path and auth. See `AzureChatCompletionsAdapter` for the
  # sibling amending the other protocol Azure serves: the two put the
  # deployment in different places entirely, which is why this is a separate
  # file rather than a shared one.
  class AzureResponsesAdapter < ResponsesAdapter
    def initialize(@api_version : String, vendor : String? = nil,
                   reasoning_unit : Capability::ReasoningUnit? = nil)
      super(vendor, reasoning_unit)
    end

    # Unlike Chat Completions, Azure's Responses surface does not put the
    # deployment in the path — confirmed against a live deployment's own
    # portal, not documentation, which disagreed with itself on this point.
    # The deployment name rides in the body as `model`, exactly as
    # `Protocol::Responses::Mapper` already writes it for plain OpenAI.
    def path(model : String) : String
      "/openai/responses?api-version=#{@api_version}"
    end

    def headers(credential : String?) : HTTP::Headers
      api_key(credential)
    end
  end
end
