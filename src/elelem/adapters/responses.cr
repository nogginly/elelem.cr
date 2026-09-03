require "./adapter"
require "../protocol/responses/mapper"
require "../protocol/responses/export"
require "../protocol/responses/stream"

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
      request, report, exporter = build(session, model, policy, retention, max_tokens, options)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end

    def prepare_stream(session : MPSH::Session, model : String, policy : Capability::Policy,
                       retention : Capability::ReasoningRetention, max_tokens : Int32,
                       options : Options = Options.new) : StreamExchange?
      request, report, exporter = build(session, model, policy, retention, max_tokens, options)

      StreamExchange.new(request.with_stream(true).to_json, report,
        Protocol::Responses::Assembler.new(exporter))
    end

    # One mapping, whichever way the reply is going to arrive.
    #
    # Shared rather than duplicated because the exporter must be built from
    # *this* mapper's `CallIdTable`, and two copies of that pairing is exactly
    # the thing `Exchange`'s comment says the design exists to make impossible
    # to get wrong.
    private def build(session : MPSH::Session, model : String, policy : Capability::Policy,
                      retention : Capability::ReasoningRetention, max_tokens : Int32,
                      options : Options)
      mapper = Protocol::Responses::Mapper.new(narrowed(model))
      request, report = mapper.map(session, model, policy, retention, options)
      {request, report, Protocol::Responses::Exporter.new(mapper.calls)}
    end
  end
end
