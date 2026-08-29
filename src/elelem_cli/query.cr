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
      session << reply

      {reply, report}
    end
  end
end
