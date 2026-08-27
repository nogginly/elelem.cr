require "http/headers"
require "../options"
require "../capability/catalog"

module Elelem
  # Everything a protocol knows about being spoken over a wire: where to post,
  # what headers to send, and how to read what comes back.
  #
  # It exists so `Client` knows nothing about any protocol. A fifth protocol
  # adds a file under `adapters/` and touches no client code — which is the
  # same reason the `protocol/` directories exist, applied one layer up.
  # Which protocol a provider speaks. Named `ProtocolKind` rather than
  # `Protocol` because the latter is already the namespace holding the four
  # implementations, and a nested enum of that name would shadow it.
  enum ProtocolKind
    ChatCompletions
    Responses
    Anthropic
    Gemini
  end

  abstract class Adapter
    # The vendor this deployment honours opaque data for. See `narrowed`.
    getter vendor : String?

    # Which reasoning unit this deployment wants, where the protocol spells
    # both. Set only to overrule the catalog — see `narrowed(model)`.
    getter reasoning_unit : Capability::ReasoningUnit?

    # Declared once here; every adapter inherits it, since the vendor question
    # is the same one for all four protocols.
    def initialize(@vendor : String? = nil,
                   @reasoning_unit : Capability::ReasoningUnit? = nil)
    end

    # A prepared request and the means to read its reply.
    #
    # The split is deliberate. `prepare` builds a body, `Server#post` sends it,
    # `read` turns the result into a message — three steps rather than one, so
    # streaming can later slot between the second and third without rewriting
    # either. It also makes the mapper/exporter pairing structural: `read`
    # closes over an exporter built from the mapper's own `CallIdTable`, so
    # there is no way to forget to share it.
    struct Exchange
      getter body : String
      getter report : Capability::Report

      def initialize(@body : String, @report : Capability::Report,
                     @reader : Proc(String, MPSH::Message))
      end

      def read(response_body : String) : MPSH::Message
        @reader.call(response_body)
      end
    end

    abstract def profile : Capability::Profile
    abstract def path(model : String) : String
    abstract def prepare(session : MPSH::Session, model : String,
                         policy : Capability::Policy,
                         retention : Capability::ReasoningRetention,
                         max_tokens : Int32,
                         options : Options) : Exchange

    # Protocol-specific auth and versioning. The credential is the server's;
    # how it is spelled on the wire is the protocol's.
    def headers(credential : String?) : HTTP::Headers
      HTTP::Headers{"content-type" => "application/json"}
    end

    # Pulled out of a non-2xx body so a caller sees the provider's own words.
    # Best-effort by design: an error object is the least standardized thing
    # any of these protocols returns, and a compatibility layer returning a
    # plausible status with an implausible body must not turn into a parse
    # crash on top of the original failure.
    def error_detail(body : String) : String?
      nil
    end

    # Narrowing only.
    #
    # A profile says what the *protocol* can express. A deployment may honour
    # less — Ollama's Anthropic-compatible endpoint ignores thinking
    # signatures rather than validating them — and may never honour more. The
    # asymmetry is why this direction is the only one offered: being wrongly
    # pessimistic costs fidelity and says so in an annotation, while being
    # wrongly optimistic sends a signature that a real endpoint rejects, and
    # breaks the turn.
    #
    # Implemented by reassigning `metadata_key`, so `Resolver#own?` stops
    # recognising the vendor's opaque data and the existing degradation path
    # handles the rest. No new machinery, and nothing to keep in step.
    def narrowed : Capability::Profile
      key = @vendor
      return profile unless key && key != profile.metadata_key
      profile.with_metadata_key(key)
    end

    # The same profile, narrowed for one model.
    #
    # Two protocols spell reasoning control both ways and reject being handed
    # both, and which unit a deployment wants is a fact about the model rather
    # than the protocol. So the last narrowing happens here, per call, because
    # here is the first place the model name is known.
    #
    # Precedence: an explicit unit on the provider wins, since it is a claim
    # the operator made deliberately; otherwise the catalog answers; otherwise
    # the optimistic default stands. A no-op on the two protocols whose unit
    # was never ambiguous.
    def narrowed(model : String) : Capability::Profile
      base = narrowed
      if unit = @reasoning_unit
        return base.reasoning_unit.either? ? base.with_reasoning_unit(unit) : base
      end
      Capability::Catalog.narrow(base, model)
    end

    private def bearer(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      credential.try { |value| headers["authorization"] = "Bearer #{value}" }
      headers
    end

    # Azure's spelling, shared by every Azure adapter regardless of which
    # protocol it carries: the credential is a plain header value, never a
    # bearer token.
    private def api_key(credential : String?) : HTTP::Headers
      headers = HTTP::Headers{"content-type" => "application/json"}
      credential.try { |value| headers["api-key"] = value }
      headers
    end

    # Both OpenAI protocols and Anthropic nest the message the same way.
    private def nested_error(body : String) : String?
      JSON.parse(body)["error"]?.try(&.["message"]?).try(&.as_s?)
    rescue JSON::ParseException
      nil
    end
  end
end
