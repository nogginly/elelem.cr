require "./server"
require "./adapter"

module Elelem
  # A server speaking one protocol.
  #
  # Three axes meet here and none collapses into another:
  #
  # - **protocol** — the wire shape, described by a `Capability::Profile`
  # - **server** — the deployment, which owns the host and the connection
  # - **vendor** — whose opaque data this endpoint actually honours
  #
  # Ollama is the case that forces them apart: one server, three protocols,
  # none of them its own vendor. A gateway forces them apart the other way —
  # OpenRouter fronting Claude is `server: openrouter, vendor: anthropic`,
  # because the opaque data really is Anthropic's and really does replay.
  class Provider
    getter server : Server
    getter adapter : Adapter
    getter default_max_tokens : Int32

    # `vendor` answers "will this endpoint honour opaque data", which is a
    # different question from "what is this protocol called".
    #
    # The default is pessimistic and falls out of comparing names rather than
    # needing a flag: a server called `anthropic` speaking the Anthropic
    # protocol is Anthropic and inherits its vendor identity; a server called
    # `ollama` speaking the same protocol does not, so its profile is narrowed
    # and a Claude-issued thinking signature degrades rather than being
    # replayed to an endpoint that cannot validate it.
    #
    # Overriding is for gateways that pass opaque data through untouched. It is
    # a claim about someone else's infrastructure, so it is deliberate — and
    # the cost of being wrong is a rejected turn, where the cost of being
    # needlessly cautious is only a recorded loss.
    # `reasoning_unit` overrules the model catalog, and exists for the case the
    # catalog cannot answer: a deployment name that carries no model identity.
    # Azure is the example — `prod-reasoning-2` says nothing about which model
    # answers — and it is the same fact that will later prove path and auth are
    # protocol-*plus*-deployment concerns.
    def self.for(server : Server, protocol : ProtocolKind, vendor : String? = nil,
                 default_max_tokens : Int32 = Elelem::Protocol::Anthropic::DEFAULT_MAX_TOKENS,
                 reasoning_unit : Capability::ReasoningUnit? = nil) : Provider
      canonical = case protocol
                  in ProtocolKind::ChatCompletions then Elelem::Protocol::ChatCompletions::METADATA_KEY
                  in ProtocolKind::Responses       then Elelem::Protocol::Responses::METADATA_KEY
                  in ProtocolKind::Anthropic       then Elelem::Protocol::Anthropic::METADATA_KEY
                  in ProtocolKind::Gemini          then Elelem::Protocol::Gemini::METADATA_KEY
                  end

      resolved = vendor || (server.name == canonical ? canonical : server.name)

      adapter = case protocol
                in ProtocolKind::ChatCompletions then ChatCompletionsAdapter.new(resolved, reasoning_unit)
                in ProtocolKind::Responses       then ResponsesAdapter.new(resolved, reasoning_unit)
                in ProtocolKind::Anthropic       then AnthropicAdapter.new(resolved, reasoning_unit)
                in ProtocolKind::Gemini          then GeminiAdapter.new(resolved, reasoning_unit)
                end

      # Loud, and at construction rather than at request time: an override
      # naming a unit the protocol never spelled is a claim about the wire that
      # the wire does not support, which is the direction narrowing refuses.
      if unit = reasoning_unit
        declared = adapter.profile.reasoning_unit
        unless declared.either? || declared == unit
          raise ArgumentError.new(
            "#{declared} is the reasoning unit #{adapter.profile.provider} spells; " \
            "#{unit} cannot be requested of it")
        end
      end

      new(server, adapter, default_max_tokens)
    end

    def initialize(@server : Server, @adapter : Adapter,
                   @default_max_tokens : Int32 = Elelem::Protocol::Anthropic::DEFAULT_MAX_TOKENS)
    end

    # What this deployment can express, after any narrowing. Worth inspecting
    # before a handoff: it is the honest answer to "what will I lose".
    def profile : Capability::Profile
      @adapter.narrowed
    end

    # The same answer for one model, which is the form worth asking before a
    # handoff: on two protocols the reasoning unit is not settled until a model
    # is named.
    def profile(model : String) : Capability::Profile
      @adapter.narrowed(model)
    end

    def vendor : String?
      @adapter.vendor
    end
  end
end
