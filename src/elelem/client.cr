require "./provider"

module Elelem
  # One request per `send`. No loop, no tool dispatch, no retries.
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
      once(session, model, policy, retention, max_tokens, options)
    end

    # The same turn, watched while it happens.
    #
    # ```
    # reply, report = client.send(session, "gpt-5") do |event, turn|
    #   print event.text if event.is_a?(Elelem::Streaming::TextDelta)
    #   turn.stop if cancelled?
    # end
    # ```
    #
    # **Passing a block is the request to stream; there is no flag.** An
    # earlier draft of the design called for one, and once the block signature
    # was settled it had nothing left to mean: "stream without watching" is
    # served by an empty block, and "ignore the block I passed" is a trap
    # rather than a feature. A caller who wants the connection kept warm
    # through a long generation writes `send(session, model) { }`.
    #
    # **The reply is the same `MPSH::Message` either way**, which is the whole
    # point of the arrangement and not a claim this method has to uphold by
    # care: frames become the protocol's own `Wire::Response` and take the same
    # `export_reply` a body would have taken.
    #
    # Adapters that have not grown an assembler yet fall through to one body.
    # Silent in the events — there are none — but not silent in the result:
    # `Report#streamed` says what happened.
    def send(session : MPSH::Session, model : String,
             policy : Capability::Policy? = nil,
             retention : Capability::ReasoningRetention? = nil,
             max_tokens : Int32? = nil,
             options : Options = Options.new,
             & : Streaming::Event, Streaming::Turn ->) : {MPSH::Message, Capability::Report}
      adapter = provider.adapter
      streamed = adapter.prepare_stream(session, model,
        policy || @policy,
        retention || @retention,
        max_tokens || provider.default_max_tokens,
        options)

      return once(session, model, policy, retention, max_tokens, options) unless streamed

      turn = Streaming::Turn.new
      assembler = streamed.assembler
      report = streamed.report

      # Every annotation already exists: mapping happened in `prepare_stream`,
      # before anything was sent. Emitting them at the head of the stream is
      # what "the request was degraded before it left" honestly looks like on a
      # timeline — holding them back to the end would be the misleading
      # version.
      #
      # `raised` rather than `annotation` for the block parameter, because
      # `annotation` is a keyword and the parser reads a bare one in expression
      # position as the start of a definition.
      report.annotations.each do |raised|
        yield Streaming::AnnotationRaised.new(raised), turn
      end

      server = provider.server
      server.stream(adapter.path(model), adapter.headers(server.credential), streamed.body,
        ->(body : String) { adapter.error_detail(body) }) do |frame|
        assembler.absorb(frame) { |event| yield event, turn }
        !turn.stopped?
      end

      # A stream that ended without a terminal frame, that nobody asked to end,
      # is a transport failure — and raising is what keeps the session clean:
      # the caller appends nothing, so nothing is left holding a half-finished
      # turn. That is deliberately *not* an answer to `SCOPE.md`'s repair
      # question; it is the honest behaviour until there is one, and repair may
      # well soften it to a returned partial reply once it can say what a
      # partial reply should contain.
      #
      # A stopped turn takes the other branch and returns what arrived, which
      # is the whole reason the assembler accumulates finished items rather
      # than keeping only the terminal frame.
      unless assembler.complete? || turn.stopped?
        raise Protocol::StreamError.new(server.name,
          "the stream ended before the reply was complete")
      end

      report.streamed = true
      {assembler.finish, report}
    end

    private def once(session : MPSH::Session, model : String,
                     policy : Capability::Policy?,
                     retention : Capability::ReasoningRetention?,
                     max_tokens : Int32?,
                     options : Options) : {MPSH::Message, Capability::Report}
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
