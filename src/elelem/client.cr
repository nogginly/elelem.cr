require "./provider"

module Elelem
  # One request per `send`. No loop, no tool dispatch, no retries, no
  # streaming.
  #
  # The turn loop belongs to the caller, which is what keeps this a translator
  # rather than an agent framework:
  #
  # ```
  # loop do
  #   reply, report = client.send(session, "llama3.2")
  #   session << reply
  #
  #   calls = reply.content.select(MPSH::ToolCallBlock).reject(&.server_executed?)
  #   break if calls.empty?
  #
  #   session << MPSH::Message.new(MPSH::Role::User, calls.map { |call| dispatch(call) })
  # end
  # ```
  #
  # The session stays the caller's throughout. A client-owned session would be
  # the provider-owns-history model by another route, and that model is
  # portable only at save points — this one is portable at every turn.
  class Client
    getter provider : Provider
    getter policy : Capability::Policy
    getter retention : Capability::ReasoningRetention

    def initialize(@provider : Provider,
                   @policy : Capability::Policy = Capability::Policy::Compensating,
                   @retention : Capability::ReasoningRetention = Capability::ReasoningRetention::All)
    end

    # Returns the reply and what it cost to get there. Both matter: a caller
    # that ignores the report is a caller that will not notice a silent
    # degradation, which is the failure this whole design is arranged against.
    #
    # `max_tokens` defaults per provider and is overridable per call, because
    # it is mostly a deployment fact and occasionally a request one. Only the
    # Anthropic protocol requires it; the others ignore it.
    def send(session : MPSH::Session, model : String,
             policy : Capability::Policy? = nil,
             retention : Capability::ReasoningRetention? = nil,
             max_tokens : Int32? = nil,
             options : Options = Options.new) : {MPSH::Message, Capability::Report}
      exchange = provider.adapter.prepare(session, model,
        policy || @policy,
        retention || @retention,
        max_tokens || provider.default_max_tokens,
        options)

      reply = exchange.read(transmit(model, exchange.body))
      {reply, exchange.report}
    end

    # Kept separate from `prepare` and `read` so a streaming implementation has
    # a seam to occupy without disturbing either. It is also the only method
    # here that touches a network, which makes everything else testable
    # offline.
    private def transmit(model : String, body : String) : String
      adapter = provider.adapter
      server = provider.server

      server.post(adapter.path(model), adapter.headers(server.credential), body,
        ->(error_body : String) { adapter.error_detail(error_body) })
    end
  end
end
