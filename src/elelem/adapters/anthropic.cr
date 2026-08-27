require "./adapter"
require "../protocol/anthropic/mapper"
require "../protocol/anthropic/export"

module Elelem
  class AnthropicAdapter < Adapter
    def profile : Capability::Profile
      Protocol::Anthropic::PROFILE
    end

    def path(model : String) : String
      "/v1/messages"
    end

    def headers(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{
        "content-type"      => "application/json",
        "anthropic-version" => Protocol::Anthropic::API_VERSION,
      }
      credential.try { |value| headers["x-api-key"] = value }
      headers
    end

    def error_detail(body : String) : String?
      nested_error(body)
    end

    # The one protocol with a required parameter the others do not have, which
    # is why `max_tokens` is threaded through every `prepare` and ignored by
    # three of them. Better a visible seam than a per-protocol options bag.
    def prepare(session : MPSH::Session, model : String, policy : Capability::Policy,
                retention : Capability::ReasoningRetention, max_tokens : Int32,
                options : Options = Options.new) : Exchange
      mapper = Protocol::Anthropic::Mapper.new(narrowed(model))
      request, report = mapper.map(session, model, policy, retention, max_tokens, options)
      exporter = Protocol::Anthropic::Exporter.new(mapper.calls)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end
  end
end
