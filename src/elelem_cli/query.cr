require "../elelem"
require "./display"
require "./output"
require "./progress"

module Elelem::Cli
  # Both `start` and `continue` are this, differing only in whether `session`
  # arrives empty or loaded from disk. Kept separate from either command so
  # neither has to know the other exists.
  module Query
    extend self

    # `reasoning` and `retention` arrive as `nil` unless the deployment said
    # otherwise, and `nil` is passed straight through rather than being
    # replaced with a default here. `Client#send` already falls back to its own
    # settings for `retention`, and an absent `Options#reasoning` emits nothing
    # on any protocol — so a deployment that configures neither produces the
    # same request body it produced before either option existed.
    #
    # `display` decides what the terminal does while the answer arrives;
    # `indicator` is the ticker already up around the call, handed in so the
    # streaming path can take it down on the first delta and put it back up
    # during a tool call.
    def run(provider : Provider, model : String, session : MPSH::Session,
            prompt : String,
            reasoning : Reasoning::Request? = nil,
            retention : Capability::ReasoningRetention? = nil,
            display : Display = Display.new(false, false),
            indicator : Progress? = nil) : {MPSH::Message, Capability::Report}
      session << MPSH::Message.user(prompt)

      client = Client.new(provider)
      options = Options.new(reasoning: reasoning)

      reply, report =
        if display.streaming?
          stream(client, session, model, retention, options, display, indicator)
        else
          client.send(session, model, retention: retention, options: options)
        end

      # What is archived is repaired; what is returned is what arrived.
      #
      # The two differ only for a cut turn, and only by its tool calls, but
      # the split is the point. A dangling call in a snapshot is a session
      # that cannot be continued — by this CLI, by another one, on another
      # provider — which is the single property the archive exists to keep.
      # The caller still gets the unrepaired reply, because a person is
      # entitled to see what the model actually said before it was cut.
      #
      # A cut turn that produced nothing but calls repairs to nothing, and
      # nothing is what gets appended. The user prompt stays: it was asked,
      # and the next turn reads better with it there than without.
      if repaired = MPSH::Repair.repaired(reply)
        session << repaired
      end

      {reply, report}
    end

    # The streamed turn.
    #
    # ## What the block may not do
    #
    # This block is called from inside `Server#stream`, which means it is
    # inside a captured proc, which means the `yield` **keyword** is illegal
    # anywhere it reaches — see `server.cr` on why `exec` is called directly.
    # Nothing here yields. Blocking on IO or on a channel is a different thing
    # entirely and is fine; `Progress#stop` waits on one.
    #
    # ## Why annotations are watched and not shown
    #
    # `AnnotationRaised` arrives at the head of the stream, before any content,
    # because every annotation exists before the request leaves. The same
    # annotations are in `report`, which both verbs already print through
    # `warn_lossy` after the reply. Showing them twice, or showing them here
    # and not there, would make a streamed run and an unstreamed one disagree
    # about a session's stderr for no gain.
    private def stream(client : Client, session : MPSH::Session, model : String,
                       retention : Capability::ReasoningRetention?,
                       options : Options,
                       display : Display,
                       indicator : Progress?) : {MPSH::Message, Capability::Report}
      Output.tune_colour

      printed = false
      thinking = false

      reply, report = client.send(session, model, retention: retention, options: options) do |event, _turn|
        case event
        in Streaming::TextDelta
          indicator.try(&.stop)
          if thinking
            Output.reasoning_close
            thinking = false
          end
          printed = true
          Output.text_delta(event.text)
        in Streaming::ReasoningDelta
          if display.show_reasoning?
            indicator.try(&.stop)
            unless thinking
              Output.reasoning_open
              thinking = true
            end
            Output.reasoning_delta(event.text)
          end
        in Streaming::ToolCallStarted
          # The pause about to happen is a tool call, not a stall. The label is
          # the whole reason `Progress` made it settable.
          if thinking
            Output.reasoning_close
            thinking = false
          end
          indicator.try do |ticker|
            ticker.label = "calling #{event.name}"
            ticker.start
          end
        in Streaming::AnnotationRaised
          # Reported once, after the reply, by `warn_lossy`.
        in Streaming::ProviderDelta
          # Namespaced vendor detail with no canonical meaning to render.
        end
      end

      Output.reasoning_close if thinking
      Output.end_stream if printed

      {reply, report}
    end
  end
end
