require "./adapter"
require "../protocol/gemini/mapper"
require "../protocol/gemini/export"

module Elelem
  class GeminiAdapter < Adapter
    def profile : Capability::Profile
      Protocol::Gemini::PROFILE
    end

    # The only protocol that puts the model in the path rather than the body,
    # which is why `path` takes it at all.
    def path(model : String) : String
      "/v1beta/models/#{URI.encode_path_segment(model)}:generateContent"
    end

    def headers(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      # Header form rather than the `?key=` query parameter: a credential in a
      # URL ends up in logs and proxy traces.
      credential.try { |value| headers["x-goog-api-key"] = value }
      headers
    end

    # Gemini wraps its error in the same envelope, but may also return a bare
    # array of them. Best-effort, as above.
    def error_detail(body : String) : String?
      nested_error(body)
    end

    def prepare(session : MPSH::Session, model : String, policy : Capability::Policy,
                retention : Capability::ReasoningRetention, max_tokens : Int32,
                options : Options = Options.new) : Exchange
      mapper = Protocol::Gemini::Mapper.new(narrowed(model))
      request, report = mapper.map(session, model, policy, retention, options)
      exporter = Protocol::Gemini::Exporter.new(mapper.calls)

      Exchange.new(request.to_json, report, ->(body : String) { exporter.export_reply(body) })
    end
  end
end
