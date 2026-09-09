require "../elelem"

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
    def run(provider : Provider, model : String, session : MPSH::Session,
            prompt : String,
            reasoning : Reasoning::Request? = nil,
            retention : Capability::ReasoningRetention? = nil) : {MPSH::Message, Capability::Report}
      session << MPSH::Message.user(prompt)

      client = Client.new(provider)
      reply, report = client.send(session, model,
        retention: retention,
        options: Options.new(reasoning: reasoning))

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
  end
end
