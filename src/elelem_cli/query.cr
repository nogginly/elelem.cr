require "../elelem"

module Elelem::Cli
  # Both `start` and `continue` are this, differing only in whether `session`
  # arrives empty or loaded from disk. Kept separate from either command so
  # neither has to know the other exists.
  module Query
    extend self

    def run(provider : Provider, model : String, session : MPSH::Session,
            prompt : String) : {MPSH::Message, Capability::Report}
      session << MPSH::Message.user(prompt)

      client = Client.new(provider)
      reply, report = client.send(session, model)
      session << reply

      {reply, report}
    end
  end
end
