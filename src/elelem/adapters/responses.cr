require "./adapter"
require "../protocol/responses/mapper"
require "../protocol/responses/export"

module Elelem
  class ResponsesAdapter < Adapter
    def profile : Capability::Profile
      Protocol::Responses::PROFILE
    end

    def path(model : String) : String
      "/v1/responses"
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
      mapper = Protocol::Responses::Mapper.new(narrowed(model))
      request, report = mapper.map(session, model, policy, retention, options)
      exporter = Protocol::Responses::Exporter.new(mapper.calls)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end
  end
end
